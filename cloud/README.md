# StudyNotch sharing: AWS stack

Everything for "Share my report" (design: `docs/architecture/share-v1-architecture.html`):
Lambda Function URL (`lambda/handler.py`), DynamoDB `share_keys`, private S3 bucket, CloudFront with
Origin Access Control, 14-day logs, optional $20 budget alert. Region: ap-southeast-1 (Singapore).
Nothing bills while idle; `cdk destroy` removes all of it.

## Test locally (no AWS)

```
python3 -m unittest discover -s cloud/tests     # 9 API tests with in-memory fakes
cd cloud && npx -y aws-cdk@2.1148.0 synth -q     # builds the CloudFormation template only
```

## One-time: let nick-aerocare deploy (as the account admin)

`nick-aerocare` cannot create stacks or roles, on purpose. Give it the smallest power that works:

1. **Bootstrap CDK once** (creates the deploy roles CDK uses). In the AWS console, signed in as the
   admin, open **CloudShell** in **ap-southeast-1** and run:
   ```
   npx -y aws-cdk@2.1148.0 bootstrap aws://480805755761/ap-southeast-1
   ```
2. **Let nick-aerocare use those roles**: IAM → Users → nick-aerocare → Add permissions → Create inline
   policy → JSON → paste `cloud/iam/nick-aerocare-cdk-deploy.json` → name it `cdk-deploy`.
   (It only allows assuming the `cdk-hnb659fds-*` roles in this account and region. CloudFormation then
   creates the resources with the bootstrap execution role.)

## Deploy (as nick-aerocare, from this folder)

```
cd cloud
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt   # first time only
npx -y aws-cdk@2.1148.0 diff
npx -y aws-cdk@2.1148.0 deploy -c alertEmail=you@example.com
```

The first deploy takes about 5-10 minutes (CloudFront). It prints:
- `ApiUrl`  → put it in `defaultShareAPI` in `Sources/StudyNotch/main.swift`, then release StudyNotch
- `SiteUrl` → where shared reports live, e.g. `https://dxxxx.cloudfront.net/r/<shareId>`

## Smoke test after deploying

```
API=<ApiUrl without the trailing slash>
curl -s -X POST $API/register -d '{}'                     # → shareId, secret, url
studynotch --report-json --shared > /tmp/r.json           # this Mac's report, without sessions
curl -s -X PUT $API/report -H "Authorization: Bearer <secret>" -H "X-Share-Id: <shareId>" \
     -H "Content-Type: application/json" --data-binary @/tmp/r.json
open "<url>"                                              # the page
curl -s -X POST $API/stop -H "Authorization: Bearer <secret>" -H "X-Share-Id: <shareId>" -d '{}'
```

Or test the app without changing the code: `STUDYNOTCH_API=<ApiUrl> studynotch`, then menu-bar icon →
Share My Report on the Web.

## Remove everything

```
npx -y aws-cdk@2.1148.0 destroy
```
