require "etc"
require "open3"
require "sidekiq/api"

module Admin
  class OperationsSnapshot
    Result = Struct.new(
      :hostname,
      :uptime_seconds,
      :load_1,
      :load_5,
      :load_15,
      :cpu_count,
      :memory_total_bytes,
      :memory_available_bytes,
      :memory_used_percent,
      :disk_total_bytes,
      :disk_available_bytes,
      :disk_used_percent,
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
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      load = load_average
      memory = memory_status
      disk = disk_status
      postgres = postgres_status
      sidekiq = sidekiq_status

      Result.new(
        hostname: ENV.fetch("HOSTNAME", Socket.gethostname),
        uptime_seconds: uptime_seconds,
        load_1: load[0],
        load_5: load[1],
        load_15: load[2],
        cpu_count: Etc.nprocessors,
        memory_total_bytes: memory[:total],
        memory_available_bytes: memory[:available],
        memory_used_percent: memory[:used_percent],
        disk_total_bytes: disk[:total],
        disk_available_bytes: disk[:available],
        disk_used_percent: disk[:used_percent],
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
        problems_by_category: Problem.group(:category).count
      )
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

    def memory_status
      data = {}
      File.readlines("/proc/meminfo").each do |line|
        key, value = line.split(":", 2)
        data[key] = value.to_i * 1024
      end

      total = data.fetch("MemTotal", 0)
      available = data.fetch("MemAvailable", 0)
      used_percent = total.positive? ? (((total - available).to_f / total) * 100).round(1) : 0.0

      {total: total, available: available, used_percent: used_percent}
    rescue
      {total: 0, available: 0, used_percent: 0.0}
    end

    def disk_status
      stdout, status = Open3.capture2("df", "-Pk", "/")
      return {total: 0, available: 0, used_percent: 0.0} unless status.success?

      fields = stdout.lines.last.to_s.split
      total = fields[1].to_i * 1024
      available = fields[3].to_i * 1024
      used_percent = fields[4].to_s.delete("%").to_f

      {total: total, available: available, used_percent: used_percent}
    rescue
      {total: 0, available: 0, used_percent: 0.0}
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
  end
end
