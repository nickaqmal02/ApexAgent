"""share-api: the StudyNotch report-sharing API (one Lambda behind a Function URL).

Routes
  POST /register   -> {shareId, secret, url}       new link; stores only sha256(secret)
  PUT  /report     (Bearer secret, X-Share-Id)     saves data/<shareId>.json after checks
  POST /stop       (Bearer secret, X-Share-Id)     revokes the link and deletes its JSON

Design notes (docs/architecture/share-v1-architecture.html):
- No accounts. The secret is the credential; the table keeps only its hash.
- The S3 key comes from the verified share id, never from the request path.
- Only JSON with the report's top-level keys, under MAX_BYTES, is stored. Nobody can host HTML here.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import string
import time

MAX_BYTES = 200_000
MIN_SECONDS_BETWEEN_UPLOADS = 60
ALLOWED_KEYS = {"subjects", "subjectCategory", "habits", "heat", "categories", "days", "bySubject",
                "totals", "sessions", "generated", "shared"}
REQUIRED_KEYS = {"habits", "heat", "categories", "totals"}
ID_ALPHABET = string.ascii_letters + string.digits
ID_LENGTH = 12   # 62^12 ≈ 3e21 possible ids

_table = None
_s3 = None


def clients():
    """boto3 clients, created on first use (tests replace them with fakes)."""
    global _table, _s3
    if _table is None:
        import boto3
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE"])
        _s3 = boto3.client("s3")
    return _table, _s3


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


def reply(status, body=None):
    return {"statusCode": status, "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
            "body": json.dumps(body if body is not None else {})}


def log(route, share_id, status, started):
    # One line per request; never the report content or the secret
    print(json.dumps({"route": route, "shareId": (share_id or "")[:4] + "…", "status": status,
                      "ms": round((time.time() - started) * 1000)}))


def handler(event, context=None):
    started = time.time()
    http = event.get("requestContext", {}).get("http", {})
    route = f'{http.get("method", "")} {event.get("rawPath", "")}'
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    share_id = headers.get("x-share-id", "")
    try:
        if route == "POST /register":
            res = register()
        elif route == "PUT /report":
            res = upload(event, headers, share_id)
        elif route == "POST /stop":
            res = stop(headers, share_id)
        else:
            res = reply(404, {"error": "not found"})
    except Exception as e:   # never leak details to the client
        print(json.dumps({"route": route, "error": type(e).__name__}))
        res = reply(500, {"error": "internal"})
    log(route, share_id, res["statusCode"], started)
    return res


def register():
    table, _ = clients()
    secret = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    for _ in range(3):   # a clash is astronomically unlikely; retry anyway
        share_id = "".join(secrets.choice(ID_ALPHABET) for _ in range(ID_LENGTH))
        try:
            table.put_item(Item={"shareId": share_id, "secretHash": sha256(secret), "createdAt": int(time.time()),
                                 "lastUpload": 0, "revoked": False},
                           ConditionExpression="attribute_not_exists(shareId)")
            break
        except Exception as e:
            if type(e).__name__ != "ConditionalCheckFailedException" and "ConditionalCheckFailed" not in str(e):
                raise
    else:
        return reply(500, {"error": "try again"})
    url = f'{os.environ["SITE_URL"].rstrip("/")}/r/{share_id}'
    return reply(200, {"shareId": share_id, "secret": secret, "url": url})


def authorised(headers, share_id):
    """The share's row if the Bearer secret matches and the link is live, else (None, status)."""
    if not share_id or len(share_id) != ID_LENGTH or any(c not in ID_ALPHABET for c in share_id):
        return None, 404
    auth = headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        return None, 403
    table, _ = clients()
    item = table.get_item(Key={"shareId": share_id}).get("Item")
    if not item or item.get("revoked"):
        return None, 404
    if not hmac.compare_digest(item["secretHash"], sha256(auth[len("Bearer "):])):
        return None, 403
    return item, 200


def body_bytes(event):
    body = event.get("body") or ""
    return base64.b64decode(body) if event.get("isBase64Encoded") else body.encode()


def upload(event, headers, share_id):
    item, status = authorised(headers, share_id)
    if not item:
        return reply(status)
    if time.time() - int(item.get("lastUpload", 0)) < MIN_SECONDS_BETWEEN_UPLOADS:
        return reply(429, {"error": "too soon"})
    raw = body_bytes(event)
    if len(raw) > MAX_BYTES:
        return reply(413, {"error": "too large"})
    try:
        data = json.loads(raw)
    except ValueError:
        return reply(400, {"error": "not json"})
    if not isinstance(data, dict) or set(data) - ALLOWED_KEYS or not REQUIRED_KEYS <= set(data):
        return reply(400, {"error": "not a report"})
    data["sessions"] = []          # never publish raw sessions, even if a client sent them
    data["shared"] = True
    table, s3 = clients()
    s3.put_object(Bucket=os.environ["BUCKET"], Key=f"data/{share_id}.json",
                  Body=json.dumps(data, separators=(",", ":")).encode(),
                  ContentType="application/json", CacheControl="max-age=60")
    table.update_item(Key={"shareId": share_id}, UpdateExpression="SET lastUpload = :t",
                      ExpressionAttributeValues={":t": int(time.time())})
    return reply(200, {"ok": True})


def stop(headers, share_id):
    item, status = authorised(headers, share_id)
    if not item:
        return reply(status)
    table, s3 = clients()
    table.update_item(Key={"shareId": share_id}, UpdateExpression="SET revoked = :r",
                      ExpressionAttributeValues={":r": True})
    s3.delete_object(Bucket=os.environ["BUCKET"], Key=f"data/{share_id}.json")
    return reply(200, {"stopped": True})
