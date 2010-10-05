Overview
=====

Edit the environment.rb to match your system.  

Start the worker
	./worker start

Submit a job
	ec2-submit.rb example.job


Dependencies
=====
* json
* [right_aws](http://rightaws.rubyforge.org/ "Cloud Computing RubyGems by RightScale")

You need to have an [AWS Account](http://aws.amazon.com/ "Amazon Web Services") and sign-up for [EC2](http://aws.amazon.com/ec2/ "Amazon Elastic Compute Cloud (Amazon EC2)"), [SQS](http://aws.amazon.com/sqs/ "Amazon Simple Queue Service (Amazon SQS)"), and [SimpleDB](http://aws.amazon.com/simpledb/ "Amazon SimpleDB").
