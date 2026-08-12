module Admin
  class FileStorageInventory
    Row = Struct.new(
      :model_file,
      :model,
      :library,
      :storage_key,
      :relative_path,
      :physical_path,
      :filename,
      :extension,
      :size,
      :modified_at,
      :source_exists,
      :digest,
      :has_render,
      keyword_init: true
    )

    Result = Struct.new(:rows, :summary, keyword_init: true)

    def self.call(scope:, limit: 250)
      new(scope: scope, limit: limit).call
    end

    def initialize(scope:, limit: 250)
      @scope = scope
      @limit = limit.to_i.clamp(1, 500)
    end

    def call
      files = @scope.includes(model: :library).limit(@limit).to_a
      rows = files.map { |model_file| build_row(model_file) }

      Result.new(
        rows: rows,
        summary: {
          shown: rows.size,
          source_present: rows.count(&:source_exists),
          source_missing: rows.count { |row| !row.source_exists },
          with_digest: rows.count { |row| row.digest.present? },
          with_render: rows.count(&:has_render),
          bytes: rows.sum { |row| row.size.to_i }
        }
      )
    end

    private

    def build_row(model_file)
      model = model_file.model
      library = model.library
      relative_path = model_file.path_within_library

      Row.new(
        model_file: model_file,
        model: model,
        library: library,
        storage_key: library.storage_key.to_s,
        relative_path: relative_path,
        physical_path: filesystem_path(library, relative_path),
        filename: model_file.filename,
        extension: model_file.extension,
        size: model_file.size,
        modified_at: model_file.mtime,
        source_exists: safe_source_exists?(model_file),
        digest: model_file.digest,
        has_render: model_file.has_render?
      )
    end

    def filesystem_path(library, relative_path)
      return nil unless library.storage_service == "filesystem"

      File.join(library.path, relative_path)
    end

    def safe_source_exists?(model_file)
      model_file.exists_on_storage?
    rescue StandardError
      false
    end
  end
end
