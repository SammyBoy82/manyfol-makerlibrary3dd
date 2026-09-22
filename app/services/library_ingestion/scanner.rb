class LibraryIngestion::Scanner
  IMPORT_ROOT = Pathname.new(
    ENV.fetch("MAKERLIBRARY_IMPORT_PATH", "/import")
  ).freeze

  def scan
    return [] unless IMPORT_ROOT.directory?

    discovered = []

    Library.where(ingestion_enabled: true).find_each do |library|
      intake =
        IMPORT_ROOT.join(
          "library-#{library.id}"
        )

      FileUtils.mkdir_p(intake)

      intake.children.sort.each do |path|
        next if ignored?(path)

        ingest = register(library, path)

        discovered << ingest if ingest
      end
    end

    discovered
  end

  private

  def register(library, path)
    fingerprint = fingerprint_for(path)

    LibraryIngest.find_or_create_by!(
      library: library,
      source_path: path.to_s,
      source_fingerprint: fingerprint
    ) do |ingest|
      ingest.source_name =
        path.basename.to_s

      ingest.source_type =
        source_type(path)

      ingest.source_origin =
        "filesystem"

      ingest.source_size =
        source_size(path)

      ingest.status =
        "pending"
    end

  rescue ActiveRecord::RecordNotUnique
    LibraryIngest.find_by(
      library: library,
      source_path: path.to_s,
      source_fingerprint: fingerprint
    )
  end

  def fingerprint_for(path)
    stat = path.stat

    Digest::SHA256.hexdigest(
      [
        path.basename.to_s,
        stat.size,
        stat.mtime.to_f
      ].join(":")
    )
  rescue SystemCallError
    Digest::SHA256.hexdigest(
      "#{path}:#{Time.current.to_f}"
    )
  end

  def source_type(path)
    return "directory" if path.directory?

    extension =
      path.extname
        .delete_prefix(".")
        .downcase

    if MediaType.archive_extensions.include?(extension)
      "archive"
    else
      "file"
    end
  end

  def source_size(path)
    return path.size if path.file?

    nil
  rescue SystemCallError
    nil
  end

  def ignored?(path)
    name = path.basename.to_s

    name.start_with?(".") ||
      SiteSettings.ignored_file?(name)
  end
end
