#!/usr/bin/env ruby
#
# SQS Jobs Processor
#
# This class will utilize to 2 Amazon SQS Queues
# for job processing
#
# Worker logic should be implemented in the process(task) method
#   This can be overriden by simply overriding the method in your
#   own file.
#

require "fileutils"
require "open3"
require "json"
require "right_aws"
require "sdb/active_sdb"

load 'environment.rb'

# Supress 'warning: peer certificate won't be verified in this SSL session'
class Net::HTTP
  alias_method :old_initialize, :initialize
  def initialize(*args)
    old_initialize(*args)
    @ssl_context = OpenSSL::SSL::SSLContext.new
    @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end
end

# Client SimpleDB connection
class Jobs < RightAws::ActiveSdb::Base
end

class Worker
  include RightAws
  
  # connection, inbound, debug
  attr_reader :sqs, :work_queue, :status_queue

  def initialize(inbound, debug, poll_rate = 3, logger = Logger.new('worker.log'))
    
    @log = logger
    params = {:logger => @log}
    
    # connect to Amazon SQS, S3, and SimpleDB
    @sqs = SqsGen2.new($access_key_id, $secret_access_key)
    @s3 = S3.new($access_key_id, $secret_access_key)
    
    ActiveSdb.establish_connection($access_key_id, $secret_access_key)
    
     # the hostname of the job executor
    @fqdn = `hostname -f`.strip
    #@ncpu = `cat /proc/cpuinfo | grep processor | wc -l`.to_i
    
    # the amount of time between queue polling
    @poll_rate = poll_rate
    
    # Connect to queues
    @log.info "#{@fqdn} connecting to inbound queue #{inbound}"
    @work_queue = @sqs.queue(inbound)
    @log.info "#{@fqdn} connecting to inbound queue #{debug}"
    @status_queue = @sqs.queue(debug)

    @bucket = nil
  end

  # fetch a job and process it or sleep
  # wait_time is the polling interval
  #
  def run
    loop do
      Signal.trap("SIGINT"){ @log.info "Caught Interrupt signal, exiting..."; exit! }
      # Continually try to receive and process jobs
      unless get_and_process_job
        delay = @poll_rate
        @log.info "Sleeping for #{delay}"
        sleep delay
      end
    end
  end

  # This method attempts to receive a message representing a job definition
  # from the work queue and execute it. If a message is received return true 
  # otherwise false

  def get_and_process_job
    msg = @work_queue.pop
    if msg
      
      print_msg(msg)
      
      @log.info("RECV #{msg.id}")
      @status_queue.push "#{@fqdn} received #{msg.id}"
      
      next_job_id = msg.id.to_s
      my_job = Jobs.find_by_job_id(next_job_id)
      
      Jobs.create('job_id' => next_job_id) unless my_job.reload
      
      my_job['status'] = "pending"
      my_job['received_at'] = Time.now.to_s
      my_job.save
      
      begin
        job = JSON.parse(msg.to_s)
      rescue ParseError => e
        @log.info("ParseError: #{e}")
        
        my_job['status'] = "error"
        my_job['error'] = "ParseError: #{e}"
        my_job.save
        
        # this is a dead letter - bad json
        # we dont want to propogate these jobs
        return true 
      end
      # wait for all the files to be availble
      
      job['files'].each do |file|
        unless File.exists?(File.basename(file))
          @log.info "Waiting for inputs from S3"
          sleep 5
        end
      end
      
      process(msg, job)
      true
    else
      false
    end
  end

  # Process the job (Hash) along with the SQS Message
  # Write the script body to Message.id.job in a temporary
  # directory.  Working directory is first downloaded from S3.
  # STDOUT is redirected to Message.id.job.o and
  # STDERR is redirected to Message.id.job.e.  All files in the
  # working directory are sent back to S3

  def process(msg, job)
    begin
      script = job["script"]
      args = job["arguments"]
      jobname = "#{msg.id}.job"
      my_job = Jobs.find_by_job_id(msg.id.to_s)
      my_job.reload
      spooldir = "/var/spool/ec2/jobs/#{msg.id}/"
      FileUtils.mkdir_p(spooldir)
      FileUtils.cd(spooldir)
      
      File.open(jobname, "w"){|f| f.write script}
      FileUtils.chmod(0755, jobname)

      bucket_name = job["bucket"]
      my_job['bucket'] = bucket_name
      my_job.save
      bucket = @s3.bucket(bucket_name)

      bucket.keys.each do |key|
        if key.name =~ /#{msg.id}\/(.*)/
          @log.info("GET #{key}")
          open("#{$1}","w"){|f| f.write key.get}
        end
      end
      @log.info "RUN #{jobname} #{args}"
      my_job['status'] = "running"
      @status_queue.push "#{msg.id} started at #{Time.now}"
      my_job['started_at'] = Time.now.to_s
      my_job.save
      Open3.popen3("./#{jobname} #{args}") do |stdin, stdout, stderr|
        stdin.close_write
        open("#{jobname}.o","w"){|o| o.write stdout.read }
        open("#{jobname}.e","w"){|e| e.write stderr.read }
      end
      @log.info "DONE #{jobname} #{args}"
      my_job['status'] = "finished"
      @status_queue.push "#{msg.id} finised at #{Time.now}"
      my_job['finished_at'] = Time.now.to_s
      my_job.save
      cwd = Dir.getwd
      @log.info "Putting files in S3"
      Dir.glob("#{cwd}/*").each do |f|
        next if !File.exists?(f) and !File.file?(f)
        key = File.join(msg.id, File.basename(f))
        if bucket.put(key, File.open(f))
          @log.info "PUT #{key}"
        end
      end
      @log.info "Done putting files"
    rescue AwsError => e
      @log.info "AwsError: #{e}"
    end
  end

  # Put the current working directory in S3
  # bucketname/msg.id/foo.txt
  # bucketname/msg.id/bar.txt

  def upload_cwd(msg)
    cwd = Dir.getwd

    Dir.glob("#{cwd}/**").each do |f|
      next unless File.exists?(f) and File.file?(f)
      key = File.join(msg.id, File.basename(f))
      if @bucket.put(key, File.open(f))
        @log.info "PUT #{key}"
      end
    end
  end

  # get the working directory from S3
  def get_wd(msg)
    @bucket.keys.each do |key|
      if key.name =~ /#{msg.id}\/(.*)/
        @log.info("GET #{key}")
        open("#{$1}","w"){|f| f.write key.get}
      end
    end
  end

  # print the entire message
  def print_msg(msg)
    puts "Message ID: " + msg.id
    puts "Message Handle: " + msg.receipt_handle
    puts "Queue ID: " + msg.queue.name
    puts "Message Body: \n" + msg.body
  end

end #Worker

worker = Worker.new($inbound_queue, $outbound_queue)
worker.run