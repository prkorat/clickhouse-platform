package main

import rego.v1

plan(rc) := {"resource_changes": [rc]}

test_open_ingress_denied if {
	some msg in deny with input as plan({
		"address": "aws_security_group_rule.bad",
		"type": "aws_security_group_rule",
		"change": {"actions": ["create"], "after": {"type": "ingress", "from_port": 9440, "to_port": 9440, "cidr_blocks": ["0.0.0.0/0"]}},
	})
	contains(msg, "0.0.0.0/0")
}

test_sg_reference_allowed if {
	count(deny) == 0 with input as plan({
		"address": "aws_security_group_rule.ok",
		"type": "aws_security_group_rule",
		"change": {"actions": ["create"], "after": {"type": "ingress", "from_port": 9440, "to_port": 9440, "source_security_group_id": "sg-123"}},
	})
}

test_imdsv1_denied if {
	some msg in deny with input as plan({
		"address": "aws_launch_template.ch",
		"type": "aws_launch_template",
		"change": {"actions": ["create"], "after": {"metadata_options": [{"http_tokens": "optional"}]}},
	})
	contains(msg, "IMDSv2")
}

test_kms_without_rotation_denied if {
	some msg in deny with input as plan({
		"address": "aws_kms_key.k",
		"type": "aws_kms_key",
		"change": {"actions": ["create"], "after": {"enable_key_rotation": false}},
	})
	contains(msg, "rotation")
}
