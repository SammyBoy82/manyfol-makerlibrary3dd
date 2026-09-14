class LibraryIngestion::Processor
  include ArchiveHelpers

  def initialize(ingest)
    @ingest = ingest
    @library = ingest.library
    @source = Pathname.new(ingest.source_path)
  end

  def process
    validate!

    duplicate_check = check_duplicate!

    if duplicate_check == :blocked
      return @ingest
    end

    @ingest.update!(
      status: "processing",
      started_at: Time.current,
      completed_at: nil,
      error_message: nil
    )

    destination =
      case @ingest.source_type
      when "archive"
        process_archive
      when "directory"
        process_directory
      when "file"
        process_file
      else
        raise "Unsupported ingest type: #{@ingest.source_type}"
      end

    verify_destination!(destination)
    remove_source!

    @ingest.update!(
      status: "completed",
      destination_path: destination.to_s,
      completed_at: Time.current,
      error_message: nil
    )

    @library.detect_filesystem_changes_later

    LibraryIngestion::PostProcessJob
      .set(wait: 15.seconds)
      .perform_later(@ingest.id)

    @ingest
  rescue => error
    mark_failed(error)
    @ingest
  end

  private

  def check_duplicate!
    result =
      LibraryIngestion::DuplicateChecker
        .new(@ingest)
        .check

    @ingest.update!(
      source_digest: result.digest,
      duplicate_status: result.status,
      duplicate_model_file: result.model_file
    )

    if result.status == "duplicate_same_library" &&
        !@ingest.duplicate_override?

      @ingest.update!(
        status: "failed",
        processing_status: "failed",
        error_message:
          "Exact duplicate already exists in this library.",
        processing_error:
          "Duplicate blocked before ingestion.",
        completed_at: Time.current
      )

      Rails.logger.warn(
        "library_ingestion_duplicate_blocked "         "ingest_id=#{@ingest.id} "         "duplicate_model_file_id=#{result.model_file&.id}"
      )

      return :blocked
    end

    :allowed
  end

  def validate!
    raise "Source no longer exists" unless @source.exist?
    raise "Library path is blank" if @library.path.blank?
    raise "Library storage is unavailable" unless @library.storage_exists?
  end

  def process_archive
    destination = destination_for_archive
    ensure_destination_available!(destination)

    temporary = temporary_path(destination)

    FileUtils.rm_rf(temporary)
    FileUtils.mkdir_p(temporary)

    begin
      extract_archive(@source, temporary)
      verify_destination!(temporary)
      FileUtils.mv(temporary, destination)
    rescue
      FileUtils.rm_rf(temporary)
      raise
    end

    destination
  end

  def process_directory
    destination =
      Pathname.new(@library.path).join(
        safe_name(@source.basename.to_s)
      )

    ensure_destination_available!(destination)

    temporary = temporary_path(destination)

    FileUtils.rm_rf(temporary)

    begin
      FileUtils.cp_r(@source.to_s, temporary.to_s)
      verify_destination!(temporary)
      FileUtils.mv(temporary, destination)
    rescue
      FileUtils.rm_rf(temporary)
      raise
    end

    destination
  end

  def process_file
    model_name =
      safe_name(@source.basename(@source.extname).to_s)

    destination =
      Pathname.new(@library.path).join(model_name)

    ensure_destination_available!(destination)

    temporary = temporary_path(destination)

    FileUtils.rm_rf(temporary)
    FileUtils.mkdir_p(temporary)

    begin
      FileUtils.cp(
        @source.to_s,
        temporary.join(@source.basename).to_s
      )

      verify_destination!(temporary)
      FileUtils.mv(temporary, destination)
    rescue
      FileUtils.rm_rf(temporary)
      raise
    end

    destination
  end

  def extract_archive(source, destination)
    strip = count_common_path_components(source)

    Archive::Reader.open_filename(
      source.to_s,
      strip_components: strip
    ) do |reader|

      reader.each_entry do |entry|
        next unless entry.file?
        next if entry.size > SiteSettings.max_file_extract_size

        filename = safe_archive_filename(entry.pathname)
        next if filename.blank?
        next if SiteSettings.ignored_file?(filename)

        reader.extract(
          entry,
          Archive::EXTRACT_SECURE,
          destination: destination.to_s
        )
      end
    end
  end

  def destination_for_archive
    basename =
      @source.basename(@source.extname).to_s

    Pathname.new(@library.path).join(
      safe_name(basename)
    )
  end

  def temporary_path(destination)
    Pathname.new(
      "#{destination}.ingest-#{@ingest.id}-tmp"
    )
  end

  def ensure_destination_available!(destination)
    raise "Destination already exists: #{destination}" if destination.exist?
  end

  def verify_destination!(destination)
    raise "Destination was not created" unless destination.exist?

    if destination.directory?
      raise "Destination is empty" if destination.children.empty?
    end
  end

  def remove_source!
    if @source.directory?
      FileUtils.rm_rf(@source)
    else
      FileUtils.rm_f(@source)
    end
  end

  def safe_name(name)
    cleaned =
      name.to_s
        .encode("UTF-8", invalid: :replace, undef: :replace)
        .scrub
        .strip
        .gsub(/[\/\\]/, "-")
        .gsub(/\A\.+/, "")
        .gsub(/\s+/, " ")

    raise "Invalid destination name" if cleaned.blank?

    cleaned
  end

  def safe_archive_filename(name)
    name.to_s
      .encode("UTF-8", invalid: :replace, undef: :replace)
      .scrub
  end

  def mark_failed(error)
    Rails.logger.error(
      "Library ingestion #{@ingest.id} failed: " \
      "#{error.class}: #{error.message}"
    )

    @ingest.update_columns(
      status: "failed",
      error_message: "#{error.class}: #{error.message}".truncate(4000),
      completed_at: Time.current,
      updated_at: Time.current
    )
  rescue => logging_error
    Rails.logger.error(
      "Unable to mark ingestion #{@ingest.id} failed: " \
      "#{logging_error.class}: #{logging_error.message}"
    )
  end
end
