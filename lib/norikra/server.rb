require 'norikra/engine'

require 'norikra/stats'
require 'norikra/logger'
include Norikra::Log

require 'norikra/typedef_manager'
require 'norikra/output_pool'
require 'norikra/typedef'
require 'norikra/query'

require 'norikra/rpc'
require 'norikra/webui'

require 'norikra/udf'

module Norikra
  class Server
    attr_accessor :running

    DEFAULT_SHUT_OFF_THRESHOLD = 90
    DEFAULT_SHUT_OFF_CHECK_INTERVAL = 10

    MICRO_PREDEFINED = {
      engine: { inbound:    { threads: 0, capacity: 0 }, outbound:   { threads: 0, capacity: 0 },
                route_exec: { threads: 0, capacity: 0 }, timer_exec: { threads: 0, capacity: 0 }, },
      rpc: { threads: 2 }, # for desktop
      web: { threads: 2 },
    }
    SMALL_PREDEFINED = {
      engine: { inbound:    { threads: 2, capacity: 0 }, outbound:   { threads: 2, capacity: 0 },
                route_exec: { threads: 2, capacity: 0 }, timer_exec: { threads: 2, capacity: 0 }, },
      rpc: { threads: 9 }, # 4core HT
      web: { threads: 9 },
    }
    MIDDLE_PREDEFINED = {
      engine: { inbound:    { threads: 4, capacity: 0 }, outbound:   { threads: 4, capacity: 0 },
                route_exec: { threads: 4, capacity: 0 }, timer_exec: { threads: 4, capacity: 0 }, },
      rpc: { threads: 17 }, # 4core HT 2CPU
      web: { threads: 17 },
    }
    LARGE_PREDEFINED = {
      engine: { inbound:    { threads: 8, capacity: 0 }, outbound:   { threads: 8, capacity: 0 },
                route_exec: { threads: 8, capacity: 0 }, timer_exec: { threads: 8, capacity: 0 }, },
      rpc: { threads: 49 }, # 6core HT 4CPU
      web: { threads: 49 },
    }

    def self.threading_configuration(conf)
      threads = case conf[:predefined]
                when :micro then MICRO_PREDEFINED
                when :small then SMALL_PREDEFINED
                when :middle then MIDDLE_PREDEFINED
                when :large then LARGE_PREDEFINED
                else MICRO_PREDEFINED
                end
      [:inbound, :outbound, :route_exec, :timer_exec].each do |type|
        [:threads, :capacity].each do |item|
          threads[:engine][type][item] = conf[:engine][type][item] if conf[:engine][type][item]
        end
      end
      threads[:rpc][:threads] = conf[:rpc][:threads] if conf[:rpc][:threads]
      threads[:web][:threads] = conf[:web][:threads] if conf[:web][:threads]
      threads
    end

    def self.log_configuration(conf)
      logconf = { level: nil, dir: nil, filesize: nil, backups: nil, bufferlines: nil }
      [:level, :dir, :filesize, :backups, :bufferlines].each do |sym|
        logconf[sym] = conf[sym] if conf[sym]
      end
      logconf
    end

    def initialize(server_options, conf={})
      if conf[:daemonize]
        outfile_path = conf[:daemonize][:outfile] || File.join(conf[:log][:dir], 'norikra.out')
        Dir.chdir("/")
        STDIN.reopen("/dev/null")
        outfile = File.open(outfile_path, 'w')
        STDOUT.reopen(outfile)
        STDERR.reopen(outfile)
        puts "working on #{$PID}"
        STDOUT.flush
      end

      @shutoff = conf[:shutoff][:enabled] || false
      @shutoff_threshold = conf[:shutoff][:threshold] || DEFAULT_SHUT_OFF_THRESHOLD
      @shutoff_check_interval = conf[:shutoff][:interval] || DEFAULT_SHUT_OFF_CHECK_INTERVAL

      @stats_path = conf[:stats][:path]
      @stats_secondary_path = conf[:stats][:secondary_path]
      @stats_suppress_dump = conf[:stats][:suppress]
      @stats_dump_interval = conf[:stats][:interval]
      @stats = if @stats_path && test(?r, @stats_path)
                 Norikra::Stats.load(@stats_path)
               else
                 nil
               end

      @host = server_options[:host] || Norikra::RPC::HTTP::DEFAULT_LISTEN_HOST
      @port = server_options[:port] || Norikra::RPC::HTTP::DEFAULT_LISTEN_PORT
      @ui_port = server_options[:ui_port] || Norikra::WebUI::HTTP::DEFAULT_LISTEN_PORT

      @ui_context_path = server_options[:ui_context_path] || "/"

      @thread_conf = self.class.threading_configuration(conf[:thread])
      @log_conf = self.class.log_configuration(conf[:log])
      @log4j_properties_path = conf[:log4j_properties_path]

      if @log4j_properties_path
        Norikra::Log.init_with_log4j_properties_path(@log4j_properties_path)
      else
        Norikra::Log.init(@log_conf[:level], @log_conf[:dir], {filesize: @log_conf[:filesize], backups: @log_conf[:backups], bufferlines: @log_conf[:bufferlines]})
      end

      info "thread configurations", @thread_conf
      info "logging configurations", @log_conf

      unless @stats_path
        warn "status file path (--stats) NOT specified"
        warn "TARGETS AND QUERIES WILL NOT BE SAVED ON SHUTDOWN !"
      end

      @typedef_manager = Norikra::TypedefManager.new
      @output_pool = Norikra::OutputPool.new

      @engine = Norikra::Engine.new(@output_pool, @typedef_manager, {thread: @thread_conf[:engine]})
      @udf_plugins = []
      @listener_plugins = []

      @rpcserver = Norikra::RPC::HTTP.new(
        engine: @engine,
        host: @host, port: @port,
        threads: @thread_conf[:rpc][:threads]
      )
      @webserver = Norikra::WebUI::HTTP.new(
        engine: @engine,
        host: @host, port: @ui_port,
        threads: @thread_conf[:web][:threads],
        context_path: @ui_context_path
      )
    end

    def run
      @engine.start

      load_plugins

      if @stats
        info "loading from stats file"
        if @stats.targets && @stats.targets.size > 0
          @stats.targets.each do |target|
            @engine.open(target[:name], target[:fields], target[:auto_field])
          end
        end
        if @stats.queries && @stats.queries.size > 0
          @stats.queries.each do |query|
            @engine.register(Norikra::Query.new(name: query[:name], group: query[:group], expression: query[:expression]))
          end
        end
      end

      @rpcserver.start
      @webserver.start

      @running = true
      info "Norikra server started."

      shutdown_proc = proc{ @running = false }
      # JVM uses SIGQUIT / SIGUSR1 for thread/heap state dumping
      [:INT, :TERM].each do |s|
        Signal.trap(s, shutdown_proc)
      end

      @dump_stats = false
      @dump_next_time = if @stats_dump_interval
                          Time.now + @stats_dump_interval
                        else
                          nil
                        end
      Signal.trap(:USR2, proc{ @dump_stats = true })

      @reload_plugins = false
      Signal.trap(:HUP, proc{ @reload_plugins = true })

      memory_stat_next = Time.now
      shut_off_mode = false

      while @running
        if @stats_path && !@stats_suppress_dump
          if @dump_stats || (@dump_next_time && Time.now > @dump_next_time)
            dump_stats
            @dump_stats = false
            @dump_next_time = Time.now + @stats_dump_interval if @dump_next_time
          end
        end

        if @reload_plugins
          begin
            load_plugins(true) # reload
          rescue => e
            warn "Error in plugin reloading", type: e.class, error: e
          end
          @reload_plugins = false
        end

        if @shutoff && memory_stat_next < Time.now
          used = @engine.memory_statistics[:heap][:used_percent]
          if !shut_off_mode && used >= @shutoff_threshold
            warn "Entering SHUT OFF mode, heap used #{used}%."
            @rpcserver.shut_off(true)
            @webserver.shut_off(true)
          elsif shut_off_mode && used < @shutoff_threshold
            warn "Recovering from SHUT OFF mode, heap used #{used}%."
            @rpcserver.shut_off(false)
            @webserver.shut_off(false)
          end
          memory_stat_next = Time.now + @shutoff_check_interval
        end

        sleep 0.3
      end
    end

    def shutdown
      info "Norikra server shutting down."
      @webserver.stop
      @rpcserver.stop
      @engine.stop
      info "Norikra server stopped."

      if @stats_path && !@stats_suppress_dump
        dump_stats
      end

      info "Norikra server shutdown complete."
    end

    def load_plugins(reload=false)
      if reload
        info "Reloading plugins by user action."
        require 'rubygems/specification'
        Gem::Specification.reset # Reset the list of known specs to find newly installed gems
      end

      info "Loading UDF plugins"
      Norikra::UDF.listup.each do |mojule|
        if mojule.is_a?(Class)
          next if @udf_plugins.include?(mojule)
          name = @engine.load(:udf, mojule)
          @udf_plugins.push(mojule)
          info "UDF loaded", name: name
        elsif mojule.is_a?(Module) && mojule.respond_to?(:plugins)
          mojule.init if mojule.respond_to?(:init)
          mojule.plugins.each do |klass|
            next if @udf_plugins.include?(klass)
            name = @engine.load(:udf, klass)
            @udf_plugins.push(klass)
            info "UDF loaded", name: name
          end
        end
      end

      info "Loading Listener plugins"
      Norikra::Listener.listup.each do |klass|
        next if @listener_plugins.include?(klass)
        @engine.load(:listener, klass)
        @listener_plugins.push(klass)
        info "Listener loaded", name: klass
      end
    end

    def dump_stats
      Norikra::Stats.generate(@engine).dump(@stats_path, @stats_secondary_path)
      info "Current status saved", path: @stats_path
    end
  end
end
