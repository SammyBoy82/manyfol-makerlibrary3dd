require "set"

module Admin
  class PhysicalStorageComparison
    Result = Struct.new(
      :library,
      :physical_source_count,
      :registered_count,
      :unregistered_paths,
      :missing_registered_paths,
      :unregistered_count,
      :missing_registered_count,
      :physical_bytes,
      keyword_init: true
    )

    MAX_RESULTS = 500

    def self.call(library:)
      new(library: library).call
    end

    def initialize(library:)
      @library = library
    end

    def call
      physical_paths = physical_source_paths
      registered_paths = registered_source_paths

      unregistered_all =
        (physical_paths - registered_paths)
          .to_a
          .sort

      missing_all =
        (registered_paths - physical_paths)
          .to_a
          .sort

      unregistered =
        unregistered_all.first(MAX_RESULTS)

      missing =
        missing_all.first(MAX_RESULTS)

      Result.new(
        library: @library,
        physical_source_count: physical_paths.size,
        registered_count: registered_paths.size,
        unregistered_paths: unregistered,
        missing_registered_paths: missing,
        unregistered_count: unregistered_all.size,
        missing_registered_count: missing_all.size,
        physical_bytes: physical_bytes(physical_paths)
      )
    end

    private

    def physical_source_paths
      Set.new(
        @library
          .list_files("**/*", File::FNM_DOTMATCH)
          .select { |path| source_file?(path) }
      )
    end

    def registered_source_paths
      Set.new(
        @library
          .model_files
          .includes(:model)
          .map(&:path_within_library)
          .select { |path| source_file?(path) }
      )
    end

    def source_file?(path)
      value = path.to_s.tr("\\", "/")

      return false if value.blank?
      return false if value.start_with?(".manyfold/")
      return false if value.include?("/.manyfold/")
      return false if value == "."
      return false if value.end_with?("/")

      true
    end

    def physical_bytes(paths)
      return nil unless @library.storage_service == "filesystem"

      paths.sum do |relative|
        begin
          File.size(
            File.join(
              @library.path,
              relative
            )
          )
        rescue StandardError
          0
        end
      end
    end
  end
end
