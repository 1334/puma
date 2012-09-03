require "rbconfig"
require 'test/unit'
require 'socket'
require 'timeout'
require 'net/http'

require 'puma/cli'
require 'puma/control_cli'

class TestIntegration < Test::Unit::TestCase
  def setup
    @state_path = "test/test_puma.state"
    @bind_path = "test/test_server.sock"
    @control_path = "test/test_control.sock"
    @tcp_port = 9998

    @server = nil
  end

  def teardown
    File.unlink @state_path rescue nil
    File.unlink @bind_path  rescue nil
    File.unlink @control_path rescue nil

    if @server
      Process.kill "INT", @server.pid
      Process.wait @server.pid
      @server.close
    end
  end

  def server(opts)
    core = "#{Gem.ruby} -rubygems -Ilib bin/puma"
    cmd = "#{core} --restart-cmd '#{core}' -b tcp://127.0.0.1:#{@tcp_port} #{opts}"
    @server = IO.popen(cmd, "r")

    loop do
      break unless IO.select([@server], nil, nil, 5)
      p @server.gets
    end

    sleep 1
    @server
  end

  def signal(which)
    Process.kill which, @server.pid
  end

  def test_stop_via_pumactl
    if defined?(JRUBY_VERSION) || RbConfig::CONFIG["host_os"] =~ /mingw|mswin/
      assert true
      return
    end

    sin = StringIO.new
    sout = StringIO.new

    cli = Puma::CLI.new %W!-q -S #{@state_path} -b unix://#{@bind_path} --control unix://#{@control_path} test/hello.ru!, sin, sout

    t = Thread.new do
      cli.run
    end

    sleep 1

    s = UNIXSocket.new @bind_path
    s << "GET / HTTP/1.0\r\n\r\n"
    assert_equal "Hello World", s.read.split("\r\n").last

    ccli = Puma::ControlCLI.new %W!-S #{@state_path} stop!, sout

    ccli.run

    assert_kind_of Thread, t.join(1), "server didn't stop"
  end

  def test_restart_closes_keepalive_sockets
    server("-q test/hello.ru")

    s = TCPSocket.new "localhost", @tcp_port
    s << "GET / HTTP/1.1\r\n\r\n"
    true until s.gets == "\r\n"

    p s.readpartial(20)
    system "kill -USR1 #{@server.pid}"
    system "kill -USR2 #{@server.pid}"

    sleep 5

    loop do
      break unless IO.select([@server], nil, nil, 5)
      p @server.gets
    end

    s.write "GET / HTTP/1.1\r\n\r\n"

    assert_raises Errno::ECONNRESET do
      Timeout.timeout(2) do
        p s.read(2)
      end
    end

    s = TCPSocket.new "localhost", @tcp_port
    s << "GET / HTTP/1.0\r\n\r\n"
    assert_equal "Hello World", s.read.split("\r\n").last
  end
end
