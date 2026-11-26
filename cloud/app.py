#!/usr/bin/env python3
"""CDK app for StudyNotch report sharing. See cloud/README.md for the commands."""
import aws_cdk as cdk

import build_site
from stack import ShareStack

build_site.build()   # always deploy the page built from the current template

app = cdk.App()
ShareStack(app, "StudyNotchShare",
           env=cdk.Environment(region=app.node.try_get_context("region") or "ap-southeast-1"),
           alert_email=app.node.try_get_context("alertEmail"),
           reserve_concurrency=int(app.node.try_get_context("reserveConcurrency") or 0),
           description="StudyNotch: share a habit report on the web (Lambda URL, DynamoDB, S3, CloudFront)")
app.synth()
