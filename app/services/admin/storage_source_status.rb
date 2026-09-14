require "json"
require "pathname"

module Admin
  class StorageSourceStatus
    DIRECTORY = Pathname.new("/config/storage-status")
    FILE_NAME = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.json\z/
    COMPLETED = %w[mounted test_passed passed failed completed renamed removed disconnected].freeze
    Status = Struct.new(:request_id, :action, :state, :message, :error, :display_name,
      :slug, :container_path, :top_level_entries, :updated_at, keyword_init: true)
    Page = Struct.new(:items, :page, :pages, :total, keyword_init: true)

    def initialize(directory: DIRECTORY)
      @directory = Pathname.new(directory)
    end

    def self.recent(limit: 10)
      new.recent(limit: limit)
    end

    def self.page(number: 1)
      new.page(number: number)
    end

    def self.clear_completed!(slug: nil)
      new.clear_completed!(slug: slug)
    end

    def recent(limit: 10)
      files.first(limit).filter_map { |path| load_status(path) }
    end

    def page(number: 1)
      entries = files
      pages = [(entries.size / 20.0).ceil, 1].max
      number = [[number.to_s.to_i, 1].max, pages].min
      Page.new(items: entries.slice((number - 1) * 20, 20).to_a.filter_map { |path| load_status(path) },
        page: number, pages: pages, total: entries.size)
    end

    def clear_completed!(slug: nil)
      if slug && !slug.match?(/\A[a-z0-9][a-z0-9-]{1,48}\z/)
        raise ArgumentError, "Invalid source"
      end
      cutoff = Time.now
      count = 0
      files.each do |path|
        begin
          before = path.lstat
          next if before.mtime > cutoff
          status = load_status(path)
          next unless status && COMPLETED.include?(status.state)
          next if slug && status.slug != slug
          after = path.lstat
          next unless after.file? && after.ino == before.ino && after.mtime == before.mtime
          path.unlink
          count += 1
        rescue Errno::ENOENT
          next
        end
      end
      count
    end

    private

    def files
      return [] unless @directory.directory? && !@directory.symlink?
      @directory.glob("*.json").filter_map do |path|
        next unless FILE_NAME.match?(path.basename.to_s)
        begin
          st = path.lstat
          [path, st.mtime] if st.file? && !st.symlink?
        rescue Errno::ENOENT
          nil
        end
      end.sort_by { |path, mtime| [mtime, path.to_s] }.reverse.map(&:first)
    end

    def load_status(path)
      data = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        next nil unless file.stat.file? && file.stat.size <= 32768
        JSON.parse(file.read)
      end
      return nil unless data.is_a?(Hash)
      Status.new(request_id: path.basename(".json").to_s, action: data["action"], state: data["state"],
        message: data["message"], error: data["error"], display_name: data["display_name"], slug: data["slug"],
        container_path: data["container_path"], top_level_entries: data["top_level_entries"],
        updated_at: data["updated_at"].is_a?(Numeric) ? Time.at(data["updated_at"]) : nil)
    rescue JSON::ParserError, SystemCallError, IOError, ArgumentError
      nil
    end
  end
end
