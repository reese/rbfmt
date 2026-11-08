Dir[File.join(__dir__, "test_*.rb")].sort.each { |file| require file }
