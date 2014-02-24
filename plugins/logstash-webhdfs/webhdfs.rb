require "plugins/namespace"
require "plugins/outputs/base"
require "stud/buffer"

# WebHdfs output
#
# Write events to files in HDFS via webhdfs restapi. You can use fields from the
# event as parts of the filename.
class LogStash::Outputs::WebHdfs < LogStash::Outputs::Base
  include Stud::Buffer

  config_name "hadoop_webhdfs"
  milestone 1

  if RUBY_VERSION[0..2] == '1.8'
    MAGIC = "\x82SNAPPY\x0"
  else
    MAGIC = "\x82SNAPPY\x0".force_encoding Encoding::ASCII_8BIT
  end
  DEFAULT_VERSION = 1
  MINIMUM_COMPATIBLE_VERSION = 1

  # The server name and port for webhdfs/httpfs connections.
  config :server, :validate => :string, :required => true

  # The Username for webhdfs.
  config :user, :validate => :string, :required => true

  # The path to the file to write. Event fields can be used here,
  # like "/var/log/plugins/%{@source_host}/%{application}"
  config :path, :validate => :string, :required => true

  # The format to use when writing events to the file. This value
  # supports any string and can include %{name} and other dynamic
  # strings.
  #
  # If this setting is omitted, the full json representation of the
  # event will be written as a single line.
  config :message_format, :validate => :string

  # Sending data to webhdfs in x seconds intervals.
  config :idle_flush_time, :validate => :number, :default => 1

  # Sending data to webhdfs if event count is above, even if store_interval_in_secs is not reached.
  config :flush_size, :validate => :number, :default => 500

  # WebHdfs open timeout, default 30s (in ruby net/http).
  config :open_timeout, :validate => :number, :default => 30

  # The WebHdfs read timeout, default 30s (in ruby net/http).
  config :read_timeout, :validate => :number, :default => 30

  # Use httpfs mode if set to true, else webhdfs.
  config :httpfs, :validate => :boolean, :default => false

  # Retry some known webhdfs errors. These may be caused by race conditions when appending to same file, etc.
  config :retry_known_errors, :validate => :boolean, :default => true

  # How long should we wait between retries.
  config :retry_interval, :validate => :number, :default => 0.5

  # How many times should we retry.
  config :retry_times, :validate => :number, :default => 5

  # Compress output. One of [false, 'snappy', 'gzip']
  config :compress, :validate => [false, "snappy", "gzip"], :default => false

  # Set snappy chunksize. Only neccessary for stream format. Defaults to 32k. Max is 65536
  # @see http://code.google.com/p/snappy/source/browse/trunk/framing_format.txt
  config :snappy_bufsize, :validate => :number, :default => 32768

  # Set snappy format. One of "stream", "file". Set to stream to be hive compatible.
  config :snappy_format, :validate => ["stream", "file"], :default => "stream"

  # Remove @timestamp field. Hive does not like a leading "@", but we need @timestamp for path calculation.
  config :remove_at_timestamp, :validate => :boolean, :default => true

  public
  def register
      # Disable concurrent access to the same file. After some experiments, webhdfs sometimes corrupts files when
      # multiple clients want to append to the same file.
      #workers_not_supported
      require 'webhdfs'
      if @compress == "gzip"
        begin
          require "zlib"
        rescue LoadError
          @logger.error("Gzip compression selected but zlib module could not be loaded.")
        end
      elsif @compress == "snappy"
        begin
          require "snappy"
        rescue LoadError
          @logger.error("Snappy compression selected but snappy module could not be loaded.")
        end
      end
      @files = {}
      @host, @port = @server.split(':')
      @client = prepare_client(@host, @port, @user)
      namenode_available(@client)
      buffer_initialize(
          :max_items => @flush_size,
          :max_interval => @idle_flush_time,
          :logger => @logger
      )
  end # def register

  public
  def receive(event)
    return unless output?(event)
    buffer_receive(event)
  end # def receive

  def prepare_client(host, port, username)
    client = WebHDFS::Client.new(host, port, username)
    if @httpfs
      client.httpfs_mode = true
    end
    client.open_timeout = @open_timeout
    client.read_timeout = @read_timeout
    if @retry_known_errors
      client.retry_known_errors = true
      client.retry_interval = @retry_interval if @retry_interval
      client.retry_times = @retry_times if @retry_times
    end
    client
  end

  def namenode_available(client)
    if client
      available = true
      begin
        client.list('/')
      rescue => e
        @logger.error("Webhdfs check request failed. (namenode: #{client.host}:#{client.port}, Exception: #{e.message})")
        available = false
      end
      available
    else
      false
    end
  end

  def flush(events=nil, teardown=false)
    return if not events
    # Avoid creating a new string for newline every time
    newline = "\n".freeze
    output_files = Hash.new { |hash, key| hash[key] = "" }
    events.collect do |event|
      path = event.sprintf(@path)
      if @remove_at_timestamp
        event.remove("@timestamp")
      end
      if @message_format
        event_as_string = event.sprintf(@message_format)
      else
        event_as_string = event.to_json
      end
      event_as_string += newline unless event_as_string.end_with? newline
      output_files[path] << event_as_string
    end
    output_files.each do |path, output|
      if @compress == "gzip"
        path += ".gz"
        output = compress_gzip(output)
      elsif @compress == "snappy"
        path += ".snappy"
        if @snappy_format == "file"
          output = compress_snappy_file(output) #compress_snappy('{"message":"dbap-bmg"}'+newline+'{"message":"dbap-bmg"}'+newline)
        elsif
          output = compress_snappy_stream(output)
        end
      end
      write_tries = 0
      while write_tries < @retry_times do
        begin
          write_data(path, output)
          break
        rescue => e
          write_tries += 1
          # Retry max_retry times. This can solve problems like leases being hold by another process. Sadly this is no
          # KNOWN_ERROR in rubys webhdfs client.
          if write_tries < @retry_times
            if write_tries > 2
              @logger.warn("Retrying webhdfs write for multiple times. Maybe you should increase retry_interval or reduce number of workers.")
            end
            sleep(@retry_interval * write_tries)
            next
          end
          # Issue error after max retries.
          @logger.error("Max write retries reached. Exception: #{e.message}")
        end
      end
    end
  end

  def compress_gzip(data)
    buffer = StringIO.new('','w')
    compressor = Zlib::GzipWriter.new(buffer)
    begin
      compressor.write data
    ensure
      compressor.close()
    end
    buffer.string
  end

  def compress_snappy_file(data)
    # Encode data to ASCII_8BIT (binary)
    data= data.encode(Encoding::ASCII_8BIT, "binary", :undef => :replace)
    buffer = StringIO.new('', 'w')
    buffer.set_encoding Encoding::ASCII_8BIT unless RUBY_VERSION =~ /^1\.8/
    compressed = Snappy.deflate(chunk)
    buffer << [compressed.size, compressed].pack("Na*")
    buffer.string
  end

  def compress_snappy_stream(data)
    # Encode data to ASCII_8BIT (binary)
    data= data.encode(Encoding::ASCII_8BIT, "binary", :undef => :replace)
    buffer = StringIO.new
    buffer.set_encoding Encoding::ASCII_8BIT unless RUBY_VERSION =~ /^1\.8/
    chunks = data.scan(/.{1,#{@snappy_bufsize}}/m)
    chunks.each do |chunk|
      compressed = Snappy.deflate(chunk)
      buffer << [chunk.size, compressed.size, compressed].pack("NNa*")
    end
    return buffer.string
  end

  def get_snappy_header!
    [MAGIC, DEFAULT_VERSION, MINIMUM_COMPATIBLE_VERSION].pack("a8NN")
  end

  def write_data(path, data)
    begin
      @client.append(path, data)
    rescue WebHDFS::FileNotFoundError
      # Add snappy header if format is "file".
      if @snappy_format == "file"
        @client.create(path, get_snappy_header! + data)
      elsif
        @client.create(path, data)
      end
    end
  end

  def teardown
    buffer_flush(:final => true)
  end # def teardown
end