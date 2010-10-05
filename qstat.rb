load 'environment.rb'

include RightAws

# SimpleDB connection
class Jobs < RightAws::ActiveSdb::Base
end

ActiveSdb.establish_connection($access_key_id, $secret_access_key, {:logger => Logger.new("qstat.log")})

puts "id\t\t\t\t\treceived\t\tstatus"

Jobs.find(:all).each do |job|
  job.reload
  puts "#{job['job_id']} #{job['received_at']} #{job['status']}"
end