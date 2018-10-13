require 'base64'
require 'mail'

# Unit test to check commands without TCP
class ProcessLineUnitTest < Minitest::Test

  # overloaded midi-smtp-server class for test
  class MidiSmtpServerProcessLineTest < MidiSmtpServerTest

    # event vars to inspect
    attr_reader :ev_auth_authentication_id
    attr_reader :ev_auth_authentication
    attr_reader :ev_message_data
    attr_reader :ev_message_delivered
    attr_reader :ev_message_bytesize

    def on_auth_event(ctx, authorization_id, authentication_id, authentication)
      # save local event data
      @ev_auth_authentication_id = authentication_id
      @ev_auth_authentication = authentication
      # return role when authenticated
      return 'supervisor' if authorization_id == '' && authentication_id == 'administrator' && authentication == 'password'
      # otherwise exit with authentification exception
      raise MidiSmtpServer::Smtpd535Exception
    end

    def on_message_data_event(ctx)
      # save local event data
      @ev_message_data = ctx[:message][:data]
      @ev_message_delivered = ctx[:message][:delivered]
      @ev_message_bytesize = ctx[:message][:bytesize]
    end

  end

  # Runs tests in alphabetical order, instead of random order.
  i_suck_and_my_tests_are_order_dependent!

  # we run all tests for the existing smtpd object
  # with same session object. so its just initialized
  # once as a class var but setup will link each test
  # the instance vars
  @@smtpd = nil
  @@session = nil

  # initialize once before tests
  def preliminary_setup_smtpd
    @@smtpd = MidiSmtpServerProcessLineTest.new(
      '2525',
      '127.0.0.1',
      1,
      auth_mode: :AUTH_OPTIONAL,
      tls_mode: :TLS_OPTIONAL,
      pipelining_extension: false,
      internationalization_extensions: true
    )
  end

  # initialize once before tests
  def preliminary_setup_session
    # prepare a session hash
    @@session = {}
    @@smtpd.process_reset_session(@@session, true)
    # enter some valid status
    @@session[:ctx][:server][:local_host] = 'localhost.local'
    @@session[:ctx][:server][:local_ip] = '127.0.0.1'
    @@session[:ctx][:server][:local_port] = '2525'
    @@session[:ctx][:server][:local_response] = 'Process line test - Welcome'
    @@session[:ctx][:server][:remote_host] = 'localhost'
    @@session[:ctx][:server][:remote_ip] = '127.0.0.1'
    @@session[:ctx][:server][:remote_port] = '65534'
    @@session[:ctx][:server][:helo_response] = 'Process line test - Greeting'
    @@session[:ctx][:server][:connected] = Time.now
  end

  # initialize before tests
  def setup
    preliminary_setup_smtpd unless @@smtpd
    preliminary_setup_session unless @@session
    # map class vars to instance vars
    @smtpd = @@smtpd
    @session = @@session
  end

  ### TEST SUITE

  def test_00_ehlo
    helo_str = 'Process line unit test'
    result = @smtpd.process_line(@session, "EHLO #{helo_str}", "\r\n")
    assert_equal "250-#{@session[:ctx][:server][:helo_response]}\r\n250-8BITMIME\r\n250-SMTPUTF8\r\n250-AUTH LOGIN PLAIN\r\n250-STARTTLS\r\n250 OK", result
    assert_equal @session[:ctx][:server][:helo], helo_str
  end

  def test_10_auth_login_simulate_fail
    result = @smtpd.process_line(@session, 'AUTH LOGIN', "\r\n")
    assert_equal '334 ' + Base64.strict_encode64('Username:'), result
    result = @smtpd.process_line(@session, Base64.strict_encode64('administrator'), "\r\n")
    assert_equal '334 ' + Base64.strict_encode64('Password:'), result
    assert_raises(MidiSmtpServer::Smtpd535Exception) { @smtpd.process_line(@session, Base64.strict_encode64('error_password'), "\r\n") }
    assert_equal 'administrator', @smtpd.ev_auth_authentication_id
    assert_equal 'error_password', @smtpd.ev_auth_authentication
    assert_equal '', @session[:ctx][:server][:authorization_id]
    assert_equal '', @session[:ctx][:server][:authentication_id]
    assert_equal '', @session[:ctx][:server][:authenticated].to_s
  end

  def test_11_auth_plain_authenticate_supervisor
    result = @smtpd.process_line(@session, 'AUTH PLAIN', "\r\n")
    assert_equal '334 ', result
    result = @smtpd.process_line(@session, 'AGFkbWluaXN0cmF0b3IAcGFzc3dvcmQ', "\r\n")
    assert_equal '235 OK', result
    assert_equal 'administrator', @smtpd.ev_auth_authentication_id
    assert_equal 'password', @smtpd.ev_auth_authentication
    assert_equal 'supervisor', @session[:ctx][:server][:authorization_id]
    assert_equal 'administrator', @session[:ctx][:server][:authentication_id]
    refute_equal '', @session[:ctx][:server][:authenticated].to_s
    assert_in_delta Time.now, @session[:ctx][:server][:authenticated],1.0
  end

  def test_20_mail_from
    address_str = 'demo@local.local'
    result = @smtpd.process_line(@session, "MAIL FROM: #{address_str}", "\r\n")
    assert_equal '250 OK', result
    assert_equal address_str, @session[:ctx][:envelope][:from]
  end

  def test_30_rcpt_to
    address_str1 = 'demo1@local.local'
    address_str2 = 'demo2@local.local'
    result = @smtpd.process_line(@session, "RCPT TO: #{address_str1}", "\r\n")
    assert_equal '250 OK', result
    result = @smtpd.process_line(@session, "RCPT TO: #{address_str2}", "\r\n")
    assert_equal '250 OK', result
    assert_equal 2, @session[:ctx][:envelope][:to].length
    assert_equal address_str1, @session[:ctx][:envelope][:to][0]
    assert_equal address_str2, @session[:ctx][:envelope][:to][1]
  end

  def test_40_data
    result = @smtpd.process_line(@session, 'DATA', "\r\n")
    assert result.start_with?('354 ')
    @smtpd.process_line(@session, 'From: <demo@local.local>', "\r\n")
    @smtpd.process_line(@session, 'To: <demo1@local.local>, <demo2@local.local>', "\r\n")
    @smtpd.process_line(@session, 'Subject: Unit Test', "\r\n")
    @smtpd.process_line(@session, 'X-test: 1', "\r\n")
    @smtpd.process_line(@session, '', "\r\n")
    @smtpd.process_line(@session, 'Welcome to message!', "\r\n")
    @smtpd.process_line(@session, 'Have fun.', "\r\n")
    @smtpd.process_line(@session, '..', "\r\n")
    result = @smtpd.process_line(@session, '.', "\r\n")
    assert result.start_with?('250 ')
    assert_equal :CMD_RSET, @session[:cmd_sequence]
    assert_equal -1, @session[:ctx][:message][:bytesize]
    assert_equal '', @session[:ctx][:message][:data]
    assert_in_delta Time.now, @smtpd.ev_message_delivered, 1
    assert_equal 138, @smtpd.ev_message_bytesize
    m = Mail.read_from_string(@smtpd.ev_message_data)
    assert_equal 'demo@local.local', m.from[0]
    assert_equal 'Unit Test', m.subject
    assert_equal 1, m.header['X-test'].value.to_i
  end

  def test_90_noop
    result = @smtpd.process_line(@session, "NOOP", "\r\n")
    assert_equal '250 OK', result
  end

  def test_91_rset
    result = @smtpd.process_line(@session, "RSET", "\r\n")
    assert_equal '250 OK', result
    assert_equal :CMD_RSET, @session[:cmd_sequence]
  end

  def test_99_quit
    result = @smtpd.process_line(@session, "QUIT", "\r\n")
    assert_equal '', result
    assert_equal :CMD_QUIT, @session[:cmd_sequence]
  end

end
