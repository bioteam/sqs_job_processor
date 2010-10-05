#!/usr/bin/env ruby

require "rubygems"
require "right_aws"
require "sdb/active_sdb"
require "json"
require "pp"

include RightAws

# Get AWS credentials from the shell environment
$access_key_id = ENV['AWS_ACCESS_KEY_ID']
$secret_access_key = ENV['AWS_SECRET_ACCESS_KEY']

$bucket_name = "maq-test"
$inbound_queue = "bioteam-all-q"
$outbound_queue = "bioteam-debug-q"

if ARGV.size < 1
  puts "Usage: #{$0} <job file> [arguments]"
  exit
end

@log = Logger.new("qsub.log")

sqs = Sqs.new($access_key_id, $secret_access_key, {:logger => @log})
s3 = S3.new($access_key_id, $secret_access_key, {:logger => @log})

# SimpleDB connection
class Jobs < RightAws::ActiveSdb::Base
end

ActiveSdb.establish_connection($access_key_id, $secret_access_key, {:logger => @log})

queue = sqs.queue($inbound_queue)
bucket = s3.bucket($bucket_name)

cwd = Dir.getwd
files_to_upload = Dir.glob("#{cwd}/**")

job = {}
job["script"] = File.open(ARGV.shift).read
job["arguments"] = ARGV
job["bucket"] = bucket.name
job["files"] = files_to_upload

sent = queue.push job.to_json
pp sent.body

job_record = Jobs.create 'job_id' => sent.id.to_s, 'bucket' => bucket.name, 'status' => "queued"
job_record.save

files_to_upload.each do |f|
  next unless File.exists?(f)
  dirname = cwd.split("/").last
  key = File.join(sent.id, File.basename(f))
  if bucket.put(key, File.open(f))
    puts "PUT #{bucket}:#{key}"
  end
end
