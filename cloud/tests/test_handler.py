"""Tests for share-api with in-memory fakes (no AWS, no network). Run: python3 -m unittest discover cloud/tests"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda"))
os.environ.update({"TABLE": "share_keys", "BUCKET": "studynotch-reports", "SITE_URL": "https://dexample.cloudfront.net"})
import handler as h  # noqa: E402


class ConditionalCheckFailedException(Exception):
    pass


class FakeTable:
    def __init__(self): self.items = {}
    def put_item(self, Item, ConditionExpression=None):
        if ConditionExpression and Item["shareId"] in self.items: raise ConditionalCheckFailedException()
        self.items[Item["shareId"]] = dict(Item)
    def get_item(self, Key):
        it = self.items.get(Key["shareId"])
        return {"Item": dict(it)} if it else {}
    def update_item(self, Key, UpdateExpression, ExpressionAttributeValues):
        field = UpdateExpression.split()[1]
        self.items[Key["shareId"]][field] = list(ExpressionAttributeValues.values())[0]


class FakeS3:
    def __init__(self): self.objects = {}
    def put_object(self, Bucket, Key, Body, ContentType, CacheControl): self.objects[Key] = (Body, ContentType, CacheControl)
    def delete_object(self, Bucket, Key): self.objects.pop(Key, None)


REPORT = {"habits": [], "heat": {}, "categories": [], "totals": {}, "sessions": [{"subject": "x"}], "generated": "now"}


def ev(method, path, body=None, secret=None, share_id=None):
    headers = {}
    if secret: headers["Authorization"] = f"Bearer {secret}"
    if share_id: headers["X-Share-Id"] = share_id
    return {"requestContext": {"http": {"method": method}}, "rawPath": path, "headers": headers,
            "body": json.dumps(body) if isinstance(body, dict) else body, "isBase64Encoded": False}


class ShareApiTests(unittest.TestCase):
    def setUp(self):
        h._table, h._s3 = FakeTable(), FakeS3()

    def register(self):
        r = h.handler(ev("POST", "/register", {}))
        self.assertEqual(r["statusCode"], 200)
        return json.loads(r["body"])

    def test_register_gives_link_and_stores_only_a_hash(self):
        b = self.register()
        self.assertEqual(len(b["shareId"]), 12)
        self.assertEqual(b["url"], f"https://dexample.cloudfront.net/r/{b['shareId']}")
        row = h._table.items[b["shareId"]]
        self.assertNotIn(b["secret"], json.dumps(row))
        self.assertEqual(row["secretHash"], h.sha256(b["secret"]))

    def test_upload_saves_json_without_sessions(self):
        b = self.register()
        r = h.handler(ev("PUT", "/report", REPORT, b["secret"], b["shareId"]))
        self.assertEqual(r["statusCode"], 200)
        body, ctype, cache = h._s3.objects[f"data/{b['shareId']}.json"]
        saved = json.loads(body)
        self.assertEqual(saved["sessions"], [])
        self.assertTrue(saved["shared"])
        self.assertEqual((ctype, cache), ("application/json", "max-age=60"))

    def test_wrong_secret_is_refused(self):
        b = self.register()
        r = h.handler(ev("PUT", "/report", REPORT, "not-the-secret", b["shareId"]))
        self.assertEqual(r["statusCode"], 403)
        self.assertEqual(h._s3.objects, {})

    def test_cannot_write_someone_elses_link(self):
        a, b = self.register(), self.register()
        r = h.handler(ev("PUT", "/report", REPORT, a["secret"], b["shareId"]))
        self.assertEqual(r["statusCode"], 403)

    def test_bad_share_ids_are_rejected_before_any_lookup(self):
        for bad in ["../../app/index", "short", "x" * 12 + "/", ""]:
            r = h.handler(ev("PUT", "/report", REPORT, "s", bad))
            self.assertEqual(r["statusCode"], 404, bad)

    def test_only_report_json_is_accepted(self):
        b = self.register()
        for body, code in [("<html>phish</html>", 400), ({"evil": 1, **REPORT}, 400), ({"habits": []}, 400),
                           ("x" * (h.MAX_BYTES + 1), 413)]:
            h._table.items[b["shareId"]]["lastUpload"] = 0
            r = h.handler(ev("PUT", "/report", body, b["secret"], b["shareId"]))
            self.assertEqual(r["statusCode"], code, str(body)[:30])

    def test_uploads_are_rate_limited(self):
        b = self.register()
        self.assertEqual(h.handler(ev("PUT", "/report", REPORT, b["secret"], b["shareId"]))["statusCode"], 200)
        self.assertEqual(h.handler(ev("PUT", "/report", REPORT, b["secret"], b["shareId"]))["statusCode"], 429)

    def test_stop_revokes_and_deletes(self):
        b = self.register()
        h.handler(ev("PUT", "/report", REPORT, b["secret"], b["shareId"]))
        r = h.handler(ev("POST", "/stop", {}, b["secret"], b["shareId"]))
        self.assertEqual(r["statusCode"], 200)
        self.assertNotIn(f"data/{b['shareId']}.json", h._s3.objects)
        h._table.items[b["shareId"]]["lastUpload"] = 0
        self.assertEqual(h.handler(ev("PUT", "/report", REPORT, b["secret"], b["shareId"]))["statusCode"], 404)

    def test_unknown_route_and_errors_leak_nothing(self):
        self.assertEqual(h.handler(ev("GET", "/admin"))["statusCode"], 404)
        h._table = None   # forces clients() to import boto3 against a missing table → handled as 500
        os.environ.pop("TABLE")
        try:
            r = h.handler(ev("POST", "/register", {}))
            self.assertEqual(r["statusCode"], 500)
            self.assertEqual(json.loads(r["body"]), {"error": "internal"})
        finally:
            os.environ["TABLE"] = "share_keys"


if __name__ == "__main__":
    unittest.main()
