task :default => :test

desc 'Run the tests'
task :test do
  FileUtils.cd 'test'
  Dir['test_*.rb'].each do |t|
    ruby t
  end
end