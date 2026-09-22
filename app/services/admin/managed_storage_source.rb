require "json"
require "pathname"

module Admin
  class ManagedStorageSource
    def self.fetch(slug)
      raise ArgumentError, "Invalid source name" unless slug.to_s.match?(/\A[a-z0-9][a-z0-9-]{1,48}\z/)
      data = JSON.parse(File.read("/config/storage-sources/#{slug}.json"))
      raise ArgumentError, "Legacy and production sources are frozen" unless data["schema_version"] == 491
      provider = data.fetch("provider")
      raise ArgumentError, "Invalid provider" unless %w[smb azure local].include?(provider)
      path = "/storage-sources/#{provider}/#{slug}"
      raise ArgumentError, "Invalid source path" unless data["container_path"] == path
      data
    end

    def self.with_lock
      File.open("/config/storage-lifecycle.lock", "r+") do |file|
        # Do not tie up a Rails request behind a slow remote mount.
        raise ArgumentError, "A storage operation is in progress; refresh and retry" unless file.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def self.verify!(data)
      raise ArgumentError, "Source is disconnected" unless data["connected"]
      path = data.fetch("container_path")
      # Check the mount table before probing, so an empty underlying directory is never accepted.
      if data["provider"] != "local"
        found = File.foreach("/proc/self/mountinfo").any? { |line| line.split[4] == path }
        raise ArgumentError, "Backing mount is unavailable" unless found
      end
      raise ArgumentError, "Storage is not readable" unless File.directory?(path) && File.readable?(path)
      raise ArgumentError, "Symbolic link sources are not supported" unless File.realpath(path) == path
      true
    end

    def self.register!(slug)
      with_lock do
        data = fetch(slug)
        verify!(data)
        raise ArgumentError, "Manyfold requires writable library storage; this source is read-only" if data["read_only"]
        path = data.fetch("container_path")
        existing = Library.find_by(storage_service: "filesystem", path: path)
        return existing if existing
        raise ArgumentError, "Storage is not writable" unless File.writable?(path)
        library = Library.new(name: data.fetch("display_name"), path: path, storage_service: "filesystem")
        # Preserve the deployed default. If absent, use the verified test library's template.
        library.path_template = Library.find_by(id: 4)&.path_template if library.path_template.blank?
        library.save!
        # Deliberately no detect_filesystem_changes_later or default-library change.
        library
      end
    end
  end
end
