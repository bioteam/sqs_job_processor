#!/usr/bin/env ruby

require "rubygems"
require "right_aws"
require "sdb/active_sdb"
require "json"

# Get AWS credentials from the shell environment
$access_key_id = ENV['AWS_ACCESS_KEY_ID']
$secret_access_key = ENV['AWS_SECRET_ACCESS_KEY']

$inbound_queue = "bioteam-all-q"
$outbound_queue = "bioteam-debug-q"

$bucket_name = "maq-test"
