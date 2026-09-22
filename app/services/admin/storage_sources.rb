require "pathname"
require "json"
module Admin
  class StorageSources
    MAX_FOLDERS = 500

    Folder = Struct.new(
      :name,
      :path,
      :registered,
      :library,
      keyword_init: true
    )

    Source = Struct.new(
      :key,
      :name,
      :kind,
      :container_path,
      :account_name,
      :container_name,
      :available,
      :readable,
      :writable,
      :mountpoint,
      :filesystem_type,
      :top_level_entries,
      :libraries,
      :models,
      :files,
      :registered_bytes,
      :folders,
      :folder_count,
      :folders_truncated,
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      built_in = [
        source(
          key: "local",
          name: "Local Data Disk",
          kind: "Local filesystem",
          path: "/libraries"
        ),

        source(
          key: "azure",
          name: adopted_azure.fetch("display_name", "Azure Blob Storage"),
          kind: adopted_azure.fetch("kind", "Azure Blob / BlobFuse2"),
          path: "/libraries-azure",
          account_name: adopted_azure["account_name"] || "3dobjectrepo",
          container_name: adopted_azure["container_name"] || "3dlibrary"
        )
      ]

      built_in + dynamic_sources
    end

    private

    def adopted_azure
      file =
        Pathname.new(
          "/config/storage-sources/azure.json"
        )

      return {} unless file.file?

      data =
        JSON.parse(
          file.read
        )

      return {} unless data["slug"].to_s == "azure"

      data

    rescue StandardError
      {}
    end


    def dynamic_sources
      directory =
        Pathname.new(
          "/config/storage-sources"
        )

      return [] unless directory.directory?

      directory
        .glob("*.json")
        .sort
        .filter_map do |file|

          begin
            data =
              JSON.parse(
                file.read
              )

            next if ["local", "azure"].include?(
              data["slug"].to_s
            )

            source(
              key: data.fetch("slug"),
              name: data.fetch("display_name"),
              kind: data.fetch("kind", "Azure Blob / BlobFuse2"),
              path: data.fetch("container_path"),
              account_name: data["account_name"],
              container_name: data["container_name"],
              enabled: data.fetch("connected", true)
            )

          rescue StandardError
            nil
          end
        end
    end


    def source(
      key:,
      name:,
      kind:,
      path:,
      account_name: nil,
      container_name: nil,
      enabled: true
    )
      dynamic_remote = path.start_with?("/storage-sources/smb/", "/storage-sources/azure/")
      backing_present = enabled && (!dynamic_remote || mountpoint?(path))
      available = backing_present && File.directory?(path)

      readable =
        available &&
        File.readable?(path)

      writable =
        available &&
        File.writable?(path)

      libraries =
        Library
          .where(storage_service: "filesystem")
          .where(
            "path = :path OR path LIKE :prefix",
            path: path,
            prefix: "#{path}/%"
          )

      library_ids =
        libraries.select(:id)

      model_count =
        Model
          .where(library_id: library_ids)
          .count

      file_scope =
        ModelFile
          .joins(:model)
          .where(
            models: {
              library_id: library_ids
            }
          )

      discovered =
        (backing_present ? discover_folders(path) : empty_folders)

      Source.new(
        key: key,
        name: name,
        kind: kind,
        container_path: path,
        account_name: account_name,
        container_name: container_name,
        available: available,
        readable: readable,
        writable: writable,
        mountpoint: mountpoint?(path),
        filesystem_type: filesystem_type(path),
        top_level_entries: (backing_present ? top_level_entries(path) : nil),
        libraries: libraries.count,
        models: model_count,
        files: file_scope.count,
        registered_bytes: file_scope.sum(:size).to_i,
        folders: discovered[:folders],
        folder_count: discovered[:count],
        folders_truncated: discovered[:truncated]
      )
    end


    def discover_folders(root)
      return empty_folders unless File.directory?(root)
      return empty_folders unless File.readable?(root)

      registered =
        Library
          .where(storage_service: "filesystem")
          .index_by do |library|
            canonical_path(library.path)
          end

      names =
        Dir.children(root)
          .select do |entry|
            begin
              File.directory?(
                File.join(
                  root,
                  entry
                )
              )
            rescue StandardError
              false
            end
          end
          .sort_by(&:downcase)

      count =
        names.size

      folders =
        names
          .first(MAX_FOLDERS)
          .map do |entry|

            path =
              File.join(
                root,
                entry
              )

            existing =
              registered[
                canonical_path(path)
              ]

            Folder.new(
              name: entry,
              path: path,
              registered: existing.present?,
              library: existing
            )
          end

      {
        folders: folders,
        count: count,
        truncated: count > folders.size
      }

    rescue StandardError
      empty_folders
    end


    def empty_folders
      {
        folders: [],
        count: 0,
        truncated: false
      }
    end


    def canonical_path(path)
      File.realpath(path)
    rescue StandardError
      File.expand_path(path.to_s)
    end


    def top_level_entries(path)
      return nil unless File.directory?(path)
      return nil unless File.readable?(path)

      Dir.children(path).size

    rescue StandardError
      nil
    end


    def mountpoint?(path)
      wanted =
        File.expand_path(path)

      File.foreach(
        "/proc/self/mountinfo"
      ) do |line|

        before, =
          line.split(
            " - ",
            2
          )

        fields =
          before.to_s.split

        next if fields.size < 5

        mount_path =
          fields[4]
            .gsub("\\040", " ")
            .gsub("\\011", "\t")
            .gsub("\\012", "\n")
            .gsub("\\134", "\\")

        return true if mount_path == wanted
      end

      false

    rescue StandardError
      false
    end


    def filesystem_type(path)
      wanted =
        File.expand_path(path)

      File.foreach(
        "/proc/self/mountinfo"
      ) do |line|

        before, after =
          line.split(
            " - ",
            2
          )

        next unless after

        fields =
          before.split

        next if fields.size < 5

        mount_path =
          fields[4]
            .gsub("\\040", " ")
            .gsub("\\011", "\t")
            .gsub("\\012", "\n")
            .gsub("\\134", "\\")

        next unless mount_path == wanted

        return after.split.first
      end

      nil

    rescue StandardError
      nil
    end
  end
end
