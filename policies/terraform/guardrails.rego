# Conftest policy for Terraform plans (design doc Section 6.2).
#   terraform show -json tfplan > plan.json && conftest test plan.json -p policies/terraform
package main

import rego.v1

changes contains rc if {
	some rc in input.resource_changes
	some action in rc.change.actions
	action in {"create", "update"}
}

# No security group rule open to the internet. Data-plane rules reference SGs, never CIDRs.
deny contains msg if {
	some rc in changes
	rc.type == "aws_security_group_rule"
	rc.change.after.type == "ingress"
	some cidr in object.get(rc.change.after, "cidr_blocks", [])
	cidr == "0.0.0.0/0"
	msg := sprintf("%s: ingress from 0.0.0.0/0 is forbidden", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_vpc_security_group_ingress_rule"
	rc.change.after.cidr_ipv4 == "0.0.0.0/0"
	msg := sprintf("%s: ingress from 0.0.0.0/0 is forbidden", [rc.address])
}

# SSH is never opened (access is SSM Session Manager only).
deny contains msg if {
	some rc in changes
	rc.type in {"aws_security_group_rule", "aws_vpc_security_group_ingress_rule"}
	object.get(rc.change.after, "from_port", -1) <= 22
	object.get(rc.change.after, "to_port", -1) >= 22
	object.get(rc.change.after, "type", "ingress") == "ingress"
	msg := sprintf("%s: port 22 must not be opened; use SSM Session Manager", [rc.address])
}

# IMDSv2 only on every instance and launch template.
deny contains msg if {
	some rc in changes
	rc.type in {"aws_instance", "aws_launch_template"}
	some mo in object.get(rc.change.after, "metadata_options", [{}])
	object.get(mo, "http_tokens", "optional") != "required"
	msg := sprintf("%s: metadata_options.http_tokens must be \"required\" (IMDSv2)", [rc.address])
}

# Every EBS volume encrypted with a customer-managed key.
deny contains msg if {
	some rc in changes
	rc.type == "aws_ebs_volume"
	not rc.change.after.encrypted
	msg := sprintf("%s: EBS volume must be encrypted", [rc.address])
}

# S3 buckets: SSE-KMS required, public access blocked.
deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket_server_side_encryption_configuration"
	some rule in rc.change.after.rule
	some d in rule.apply_server_side_encryption_by_default
	d.sse_algorithm != "aws:kms"
	msg := sprintf("%s: S3 encryption must be aws:kms with a CMK", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "aws_s3_bucket_public_access_block"
	some flag in ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]
	rc.change.after[flag] != true
	msg := sprintf("%s: %s must be true", [rc.address, flag])
}

# KMS keys rotate.
deny contains msg if {
	some rc in changes
	rc.type == "aws_kms_key"
	rc.change.after.enable_key_rotation != true
	msg := sprintf("%s: enable_key_rotation must be true", [rc.address])
}
