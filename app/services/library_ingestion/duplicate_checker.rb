class LibraryIngestion::DuplicateChecker
  BUFFER_SIZE = 1024 * 1024

  Result = Struct.new(
    :digest,
    :status,
    :model_file,
    keyword_init: true
  )

  def initialize(ingest)
    @ingest = ingest
  end

  def check
    return unchecked unless checkable_file?

    digest = digest_for_source

    existing =
      ModelFile
        .where(digest: digest)
        .includes(model: :library)
        .first

    unless existing
      return Result.new(
        digest: digest,
        status: "unique",
        model_file: nil
      )
    end

    status =
      if existing.model.library_id == @ingest.library_id
        "duplicate_same_library"
      else
        "duplicate_other_library"
      end

    Result.new(
      digest: digest,
      status: status,
      model_file: existing
    )
  end

  private

  def checkable_file?
    @ingest.source_type == "file" &&
      File.file?(@ingest.source_path)
  end

  def digest_for_source
    sha = Digest::SHA512.new

    File.open(@ingest.source_path, "rb") do |io|
      while (chunk = io.read(BUFFER_SIZE))
        sha.update(chunk)
      end
    end

    sha.hexdigest
  end

  def unchecked
    Result.new(
      digest: nil,
      status: "unchecked",
      model_file: nil
    )
  end
end
