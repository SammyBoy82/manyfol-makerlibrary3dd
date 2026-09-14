module Admin
  class FileStorageAnalytics
    LibraryRow = Struct.new(
      :library,
      :models,
      :files,
      :registered_bytes,
      :total_bytes,
      :used_bytes,
      :free_bytes,
      :used_percent,
      keyword_init: true
    )

    ExtensionRow = Struct.new(
      :extension,
      :files,
      :bytes,
      keyword_init: true
    )

    ModelRow = Struct.new(
      :model,
      :library,
      :files,
      :bytes,
      keyword_init: true
    )

    Result = Struct.new(
      :libraries,
      :extensions,
      :largest_files,
      :largest_models,
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      Result.new(
        libraries: library_rows,
        extensions: extension_rows,
        largest_files: largest_files,
        largest_models: largest_models
      )
    end

    private

    def library_rows
      model_counts =
        Model
          .group(:library_id)
          .count

      file_stats =
        ModelFile
          .joins(:model)
          .group("models.library_id")
          .pluck(
            "models.library_id",
            Arel.sql("COUNT(model_files.id)"),
            Arel.sql("COALESCE(SUM(model_files.size), 0)")
          )
          .to_h do |library_id, count, bytes|
            [
              library_id,
              {
                files: count.to_i,
                bytes: bytes.to_i
              }
            ]
          end

      Library.order(:name).map do |library|
        storage = filesystem_stats(library)
        registered = file_stats.fetch(
          library.id,
          {files: 0, bytes: 0}
        )

        LibraryRow.new(
          library: library,
          models: model_counts.fetch(library.id, 0),
          files: registered[:files],
          registered_bytes: registered[:bytes],
          total_bytes: storage[:total],
          used_bytes: storage[:used],
          free_bytes: storage[:free],
          used_percent: storage[:percent]
        )
      end
    end

    def extension_rows
      stats = Hash.new { |hash, key| hash[key] = {files: 0, bytes: 0} }

      ModelFile
        .where.not(filename: nil)
        .pluck(:filename, :size)
        .each do |filename, size|

        extension =
          File
            .extname(filename.to_s)
            .delete(".")
            .downcase
            .presence || "(none)"

        stats[extension][:files] += 1
        stats[extension][:bytes] += size.to_i
      end

      stats
        .map do |extension, values|
          ExtensionRow.new(
            extension: extension,
            files: values[:files],
            bytes: values[:bytes]
          )
        end
        .sort_by { |row| [-row.files, row.extension] }
    end

    def largest_files
      ModelFile
        .includes(model: :library)
        .where.not(size: nil)
        .order(size: :desc)
        .limit(20)
        .to_a
    end

    def largest_models
      rows =
        Model
          .joins(:model_files)
          .includes(:library)
          .group("models.id")
          .order(Arel.sql("COALESCE(SUM(model_files.size), 0) DESC"))
          .limit(20)
          .pluck(
            "models.id",
            Arel.sql("COUNT(model_files.id)"),
            Arel.sql("COALESCE(SUM(model_files.size), 0)")
          )

      models =
        Model
          .includes(:library)
          .where(id: rows.map(&:first))
          .index_by(&:id)

      rows.filter_map do |model_id, count, bytes|
        model = models[model_id]
        next unless model

        ModelRow.new(
          model: model,
          library: model.library,
          files: count.to_i,
          bytes: bytes.to_i
        )
      end
    end

    def filesystem_stats(library)
      return empty_storage_stats unless library.storage_service == "filesystem"
      return empty_storage_stats unless library.path.present?

      stat = Sys::Filesystem.stat(library.path)

      total = stat.bytes_total.to_i
      free = stat.bytes_available.to_i
      used = [total - free, 0].max

      percent =
        if total.positive?
          ((used.to_f / total) * 100).round(1)
        end

      {
        total: total,
        free: free,
        used: used,
        percent: percent
      }
    rescue StandardError
      empty_storage_stats
    end

    def empty_storage_stats
      {
        total: nil,
        free: nil,
        used: nil,
        percent: nil
      }
    end
  end
end
