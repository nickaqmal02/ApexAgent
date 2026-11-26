"""All AWS parts of StudyNotch report sharing, in one stack (docs/architecture/share-v1-architecture.html).

Nothing here bills while idle: no servers, NAT, EKS or provisioned capacity.
`cdk destroy` removes everything, including the bucket's files.
"""
from pathlib import Path

from aws_cdk import (CfnOutput, Duration, RemovalPolicy, Stack, aws_budgets as budgets,
                     aws_cloudfront as cf, aws_cloudfront_origins as origins, aws_dynamodb as ddb,
                     aws_lambda as lambda_, aws_logs as logs, aws_s3 as s3, aws_s3_deployment as s3deploy)
from constructs import Construct

HERE = Path(__file__).resolve().parent

# /r/<id>  -> the one report page; everything else unchanged. Runs at the edge, costs ~nothing.
REWRITE_JS = """
function handler(event) {
  var r = event.request;
  if (r.uri.indexOf('/r/') === 0) { r.uri = '/app/index.html'; }
  return r;
}
"""


class ShareStack(Stack):
    def __init__(self, scope: Construct, cid: str, *, alert_email=None, reserve_concurrency=0, **kw):
        super().__init__(scope, cid, **kw)

        # Private bucket: app/index.html (the page) and data/<shareId>.json (one per user)
        bucket = s3.Bucket(self, "Reports",
                           block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
                           encryption=s3.BucketEncryption.S3_MANAGED,
                           enforce_ssl=True,
                           versioned=False,
                           lifecycle_rules=[s3.LifecycleRule(prefix="data/", expiration=Duration.days(90))],
                           removal_policy=RemovalPolicy.DESTROY, auto_delete_objects=True)

        # One small row per link: shareId -> sha256(secret), createdAt, lastUpload, revoked
        table = ddb.Table(self, "ShareKeys",
                          partition_key=ddb.Attribute(name="shareId", type=ddb.AttributeType.STRING),
                          billing_mode=ddb.BillingMode.PAY_PER_REQUEST,
                          removal_policy=RemovalPolicy.DESTROY)

        # Public front door; reads the bucket through Origin Access Control (bucket stays private)
        rewrite = cf.Function(self, "RewriteShareLinks", code=cf.FunctionCode.from_inline(REWRITE_JS),
                              runtime=cf.FunctionRuntime.JS_2_0)
        dist = cf.Distribution(self, "Site",
                               default_behavior=cf.BehaviorOptions(
                                   origin=origins.S3BucketOrigin.with_origin_access_control(bucket),
                                   viewer_protocol_policy=cf.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                                   cache_policy=cf.CachePolicy.CACHING_OPTIMIZED,   # follows each object's Cache-Control
                                   function_associations=[cf.FunctionAssociation(
                                       function=rewrite, event_type=cf.FunctionEventType.VIEWER_REQUEST)]),
                               price_class=cf.PriceClass.PRICE_CLASS_200,   # includes Asia
                               comment="StudyNotch shared reports")
        site_url = f"https://{dist.distribution_domain_name}"

        # The page itself, cached at the edge for a day (new deploys invalidate it)
        s3deploy.BucketDeployment(self, "Page", sources=[s3deploy.Source.asset(str(HERE / "site"))],
                                  destination_bucket=bucket, distribution=dist, distribution_paths=["/app/*"],
                                  cache_control=[s3deploy.CacheControl.from_string("public, max-age=86400")],
                                  prune=False)   # never delete users' data/ files

        # The API: one function, three routes, behind a Function URL (no API Gateway)
        log_group = logs.LogGroup(self, "ApiLogs", retention=logs.RetentionDays.TWO_WEEKS,
                                  removal_policy=RemovalPolicy.DESTROY)
        fn = lambda_.Function(self, "ShareApi",
                              runtime=lambda_.Runtime.PYTHON_3_12, architecture=lambda_.Architecture.ARM_64,
                              handler="handler.handler", code=lambda_.Code.from_asset(str(HERE / "lambda")),
                              memory_size=256, timeout=Duration.seconds(15), log_group=log_group,
                              reserved_concurrent_executions=reserve_concurrency or None,
                              environment={"TABLE": table.table_name, "BUCKET": bucket.bucket_name, "SITE_URL": site_url})
        # Least privilege: only these actions, only here
        table.grant(fn, "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem")
        bucket.grant_put(fn, "data/*")
        bucket.grant_delete(fn, "data/*")
        url = fn.add_function_url(auth_type=lambda_.FunctionUrlAuthType.NONE)   # the secret is checked in code
        # Since Oct 2025 a public Function URL also needs lambda:InvokeFunction for "*"; this aws-cdk-lib
        # version only adds InvokeFunctionUrl. The condition limits it to calls that come through the URL.
        invoke = lambda_.CfnPermission(self, "InvokeViaUrl", action="lambda:InvokeFunction",
                                       function_name=fn.function_arn, principal="*")
        invoke.add_property_override("InvokedViaFunctionUrl", True)

        # Email at 25% and 100% of $20 a month (only when an address is given at deploy time)
        if alert_email:
            budgets.CfnBudget(self, "Budget",
                              budget=budgets.CfnBudget.BudgetDataProperty(
                                  budget_type="COST", time_unit="MONTHLY",
                                  budget_limit=budgets.CfnBudget.SpendProperty(amount=20, unit="USD")),
                              notifications_with_subscribers=[
                                  budgets.CfnBudget.NotificationWithSubscribersProperty(
                                      notification=budgets.CfnBudget.NotificationProperty(
                                          comparison_operator="GREATER_THAN", notification_type="ACTUAL",
                                          threshold=pct, threshold_type="PERCENTAGE"),
                                      subscribers=[budgets.CfnBudget.SubscriberProperty(
                                          subscription_type="EMAIL", address=alert_email)])
                                  for pct in (25, 100)])

        CfnOutput(self, "ApiUrl", value=url.url, description="Put this in defaultShareAPI (Sources/StudyNotch/main.swift)")
        CfnOutput(self, "SiteUrl", value=site_url)
        CfnOutput(self, "BucketName", value=bucket.bucket_name)
