class String
  def red
    "\e[31m#{self}\e[0m"
  end

  def green
    "\e[32m#{self}\e[0m"
  end

  def blue
    "\e[34m#{self}\e[0m"
  end

  def bold
    "\e[1m#{self}\e[22m"
  end
end

WORKDIR = File.dirname(__FILE__)
SWIFTGEN = File.join(WORKDIR, "Pods/SwiftGen/bin/swiftgen")

desc "generate"
namespace :gen do
  desc "asset"
  task :asset do
    sh "#{SWIFTGEN}"
  end
end

private

def verbose(s)
  puts s
end

def info(s)
  puts s.bold.red
end

def success(s)
  puts s.bold.green
end

def fail(s)
  abort s.bold.red
end
