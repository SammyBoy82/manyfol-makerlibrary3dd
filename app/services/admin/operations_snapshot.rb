require "etc"
require "open3"
require "sidekiq/api"
require "sys/filesystem"

module Admin
  class OperationsSnapshot
    Result = Struct.new(
      :hostname,
      :uptime_seconds,
      :host_cpu_percent,
      :load_1,
      :load_5,
      :load_15,
      :cpu_count,
      :memory_total_bytes,
      :memory_available_bytes,
      :memory_used_percent,
      :swap_total_bytes,
      :swap_used_bytes,
      :disk_total_bytes,
      :disk_available_bytes,
      :disk_used_percent,
      :container_cpu_percent,
      :container_memory_bytes,
      :container_memory_limit_bytes,
      :container_memory_percent,
      :container_uptime_seconds,
      :container_pids,
      :container_network_rx_bytes,
      :container_network_tx_bytes,
      :redis_ok,
      :postgres_ok,
      :database_size_bytes,
      :database_connections,
      :queues,
      :retries,
      :scheduled,
      :dead,
      :sidekiq_processes,
      :models,
      :model_files,
      :problems_total,
      :problems_by_category,
      :library_storage,
      :backup_status,
      :alerts,
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      load = load_average
      memory = memory_status
      disk = disk_status("/")
      postgres = postgres_status
      sidekiq = sidekiq_status
      container = container_status
      libraries = library_storage_status
      backups = backup_status

      values = {
        hostname: ENV.fetch("HOSTNAME", Socket.gethostname),
        uptime_seconds: uptime_seconds,
        host_cpu_percent: host_cpu_percent,
        load_1: load[0],
        load_5: load[1],
        load_15: load[2],
        cpu_count: Etc.nprocessors,
        memory_total_bytes: memory[:total],
        memory_available_bytes: memory[:available],
        memory_used_percent: memory[:used_percent],
        swap_total_bytes: memory[:swap_total],
        swap_used_bytes: memory[:swap_used],
        disk_total_bytes: disk[:total],
        disk_available_bytes: disk[:available],
        disk_used_percent: disk[:used_percent],
        container_cpu_percent: container[:cpu_percent],
        container_memory_bytes: container[:memory],
        container_memory_limit_bytes: container[:memory_limit],
        container_memory_percent: container[:memory_percent],
        container_uptime_seconds: container[:uptime],
        container_pids: container[:pids],
        container_network_rx_bytes: container[:network_rx],
        container_network_tx_bytes: container[:network_tx],
        redis_ok: redis_ok?,
        postgres_ok: postgres[:ok],
        database_size_bytes: postgres[:size],
        database_connections: postgres[:connections],
        queues: sidekiq[:queues],
        retries: sidekiq[:retries],
        scheduled: sidekiq[:scheduled],
        dead: sidekiq[:dead],
        sidekiq_processes: sidekiq[:processes],
        models: Model.count,
        model_files: ModelFile.count,
        problems_total: Problem.count,
        problems_by_category: Problem.group(:category).count,
        library_storage: libraries,
        backup_status: backups
      }

      values[:alerts] = build_alerts(values)
      Result.new(**values)
    end

    private

    def load_average
      File.read("/proc/loadavg").split.first(3).map(&:to_f)
    rescue
      [0.0, 0.0, 0.0]
    end

    def uptime_seconds
      File.read("/proc/uptime").split.first.to_f
    rescue
      0.0
    end

    def host_cpu_percent
      first = cpu_ticks
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep 0.15
      second = cpu_ticks
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      return 0.0 if elapsed <= 0 || first.nil? || second.nil?

      total_delta = second[:total] - first[:total]
      idle_delta = second[:idle] - first[:idle]
      return 0.0 unless total_delta.positive?

      (((total_delta - idle_delta).to_f / total_delta) * 100).round(1)
    rescue
      0.0
    end

    def cpu_ticks
      fields = File.readlines("/proc/stat").find { |line| line.start_with?("cpu ") }.split.drop(1).map(&:to_i)
      idle = fields[3].to_i + fields[4].to_i
      {total: fields.sum, idle: idle}
    rescue
      nil
    end

    def memory_status
      data = {}
      File.readlines("/proc/meminfo").each do |line|
        key, value = line.split(":", 2)
        data[key] = value.to_i * 1024
      end

      total = data.fetch("MemTotal", 0)
      available = data.fetch("MemAvailable", 0)
      used_percent = total.positive? ? (((total - available).to_f / total) * 100).round(1) : 0.0
      swap_total = data.fetch("SwapTotal", 0)
      swap_free = data.fetch("SwapFree", 0)

      {
        total: total,
        available: available,
        used_percent: used_percent,
        swap_total: swap_total,
        swap_used: [swap_total - swap_free, 0].max
      }
    rescue
      {total: 0, available: 0, used_percent: 0.0, swap_total: 0, swap_used: 0}
    end

    def disk_status(path)
      stdout, status = Open3.capture2("df", "-Pk", path.to_s)
      return {total: 0, available: 0, used_percent: 0.0, device: nil, mountpoint: nil} unless status.success?

      fields = stdout.lines.last.to_s.split
      total = fields[1].to_i * 1024
      available = fields[3].to_i * 1024
      used_percent = fields[4].to_s.delete("%").to_f

      {
        total: total,
        available: available,
        used_percent: used_percent,
        device: fields[0],
        mountpoint: fields[5]
      }
    rescue
      {total: 0, available: 0, used_percent: 0.0, device: nil, mountpoint: nil}
    end

    def directory_size(path)
      stdout, status = Open3.capture2("du", "-sk", "--", path.to_s)
      return 0 unless status.success?

      stdout.to_s.split.first.to_i * 1024
    rescue
      0
    end

    def container_status
      memory = read_integer("/sys/fs/cgroup/memory.current")
      memory_limit_raw = File.read("/sys/fs/cgroup/memory.max").strip rescue nil
      memory_limit = memory_limit_raw == "max" ? 0 : memory_limit_raw.to_i
      memory_percent = memory_limit.positive? ? ((memory.to_f / memory_limit) * 100).round(1) : 0.0

      {
        cpu_percent: container_cpu_percent,
        memory: memory,
        memory_limit: memory_limit,
        memory_percent: memory_percent,
        uptime: container_uptime,
        pids: read_integer("/sys/fs/cgroup/pids.current"),
        network_rx: container_network[:rx],
        network_tx: container_network[:tx]
      }
    rescue
      {
        cpu_percent: 0.0,
        memory: 0,
        memory_limit: 0,
        memory_percent: 0.0,
        uptime: 0.0,
        pids: 0,
        network_rx: 0,
        network_tx: 0
      }
    end

    def container_cpu_percent
      first = cgroup_cpu_usage_usec
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep 0.15
      second = cgroup_cpu_usage_usec
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      return 0.0 if elapsed <= 0 || second <= first

      capacity = elapsed * 1_000_000 * [Etc.nprocessors, 1].max
      (((second - first).to_f / capacity) * 100).round(1)
    rescue
      0.0
    end

    def cgroup_cpu_usage_usec
      line = File.readlines("/sys/fs/cgroup/cpu.stat").find { |entry| entry.start_with?("usage_usec ") }
      line.to_s.split.last.to_i
    rescue
      0
    end

    def container_uptime
      stat = File.read("/proc/1/stat").split
      start_ticks = stat[21].to_f
      ticks_per_second = Etc.sysconf(Etc::SC_CLK_TCK).to_f
      return 0.0 unless ticks_per_second.positive?

      [uptime_seconds - (start_ticks / ticks_per_second), 0.0].max
    rescue
      0.0
    end

    def container_network
      rx = 0
      tx = 0
      File.readlines("/proc/net/dev").drop(2).each do |line|
        interface, data = line.split(":", 2)
        next if interface.to_s.strip == "lo"

        fields = data.to_s.split
        rx += fields[0].to_i
        tx += fields[8].to_i
      end
      {rx: rx, tx: tx}
    rescue
      {rx: 0, tx: 0}
    end

    def read_integer(path)
      File.read(path).strip.to_i
    rescue
      0
    end

    def library_storage_status
      Library.all.map do |library|
        if library.storage_service == "filesystem"
          volume = disk_status(library.path)
          folder_bytes = directory_size(library.path)

          {
            id: library.id,
            name: library.name,
            service: library.storage_service,
            path: library.path,
            directory_bytes: folder_bytes,
            device: volume[:device],
            mountpoint: volume[:mountpoint],
            total: volume[:total],
            available: volume[:available],
            used_percent: volume[:used_percent],
            models: library.models.count,
            files: library.model_files.count
          }
        else
          {
            id: library.id,
            name: library.name,
            service: library.storage_service,
            path: library.path,
            directory_bytes: nil,
            device: nil,
            mountpoint: nil,
            total: nil,
            available: library.free_space,
            used_percent: nil,
            models: library.models.count,
            files: library.model_files.count
          }
        end
      rescue => error
        {
          id: library.id,
          name: library.name,
          service: library.storage_service,
          path: library.path,
          error: error.class.name,
          models: library.models.count,
          files: library.model_files.count
        }
      end
    end

    def backup_status
      path = ENV.fetch("MAKERLIBRARY_BACKUP_PATH", "/archive/backups")
      return {path: path, configured: false, files: 0, bytes: 0, latest: nil, latest_bytes: 0} unless Dir.exist?(path)

      files = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).select { |entry| File.file?(entry) }
      latest = files.max_by { |entry| File.mtime(entry) }

      {
        path: path,
        configured: true,
        files: files.length,
        bytes: files.sum { |entry| File.size(entry) rescue 0 },
        latest: latest && File.mtime(latest),
        latest_name: latest && File.basename(latest),
        latest_bytes: latest ? (File.size(latest) rescue 0) : 0
      }
    rescue => error
      {path: path, configured: false, files: 0, bytes: 0, latest: nil, latest_bytes: 0, error: error.class.name}
    end

    def redis_ok?
      Sidekiq.redis { |connection| connection.call("PING") == "PONG" }
    rescue
      false
    end

    def postgres_status
      connection = ActiveRecord::Base.connection
      ok = connection.select_value("SELECT 1").to_i == 1
      size = connection.select_value("SELECT pg_database_size(current_database())").to_i
      connections = connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()"
      ).to_i

      {ok: ok, size: size, connections: connections}
    rescue
      {ok: false, size: 0, connections: 0}
    end

    def sidekiq_status
      queue_names = %w[critical high scan default low federation analysis activity upgrade performance]
      queues = queue_names.index_with { |name| Sidekiq::Queue.new(name).size }

      {
        queues: queues,
        retries: Sidekiq::RetrySet.new.size,
        scheduled: Sidekiq::ScheduledSet.new.size,
        dead: Sidekiq::DeadSet.new.size,
        processes: Sidekiq::ProcessSet.new.size
      }
    rescue
      {
        queues: {},
        retries: 0,
        scheduled: 0,
        dead: 0,
        processes: 0
      }
    end

    def build_alerts(values)
      alerts = []

      alerts << {level: :danger, message: "PostgreSQL is unavailable."} unless values[:postgres_ok]
      alerts << {level: :danger, message: "Redis is unavailable."} unless values[:redis_ok]

      if values[:disk_used_percent].to_f >= 90
        alerts << {level: :danger, message: "Root disk usage is #{values[:disk_used_percent]}%."}
      elsif values[:disk_used_percent].to_f >= 80
        alerts << {level: :warning, message: "Root disk usage is #{values[:disk_used_percent]}%."}
      end

      if values[:memory_used_percent].to_f >= 90
        alerts << {level: :danger, message: "Server memory usage is #{values[:memory_used_percent]}%."}
      elsif values[:memory_used_percent].to_f >= 85
        alerts << {level: :warning, message: "Server memory usage is #{values[:memory_used_percent]}%."}
      end

      values[:library_storage].each do |storage|
        next unless storage[:used_percent]
        next if storage[:used_percent].to_f < 80

        level = storage[:used_percent].to_f >= 90 ? :danger : :warning
        alerts << {level: level, message: "Storage volume for #{storage[:name]} is #{storage[:used_percent]}% full."}
      end

      alerts << {level: :warning, message: "Sidekiq has #{values[:dead]} dead job(s)."} if values[:dead].to_i.positive?
      alerts << {level: :warning, message: "Sidekiq has #{values[:retries]} retry job(s)."} if values[:retries].to_i.positive?

      backup = values[:backup_status]
      if !backup[:configured]
        alerts << {level: :warning, message: "Backup folder is not configured or does not exist: #{backup[:path]}."}
      elsif backup[:latest].nil?
        alerts << {level: :warning, message: "Backup folder exists but contains no backup files."}
      elsif backup[:latest] < 2.days.ago
        alerts << {level: :warning, message: "Latest backup is older than 48 hours."}
      end

      alerts
    end
  end
end
