class PreviewEnrichmentCandidatesController < ApplicationController
  before_action :authorize_settings
  before_action :set_candidate, only: [:image, :approve, :reject]

  DEFAULT_MIN_CONFIDENCE = 75

  def index
    policy_scope(PreviewEnrichmentCandidate)
    @status = permitted_status
    @min_confidence = minimum_confidence
    @provider = params[:provider].presence

    scope = PreviewEnrichmentCandidate
      .includes(:model)
      .order(confidence: :desc, discovered_at: :desc, created_at: :desc)

    scope = scope.where(status: @status)
    scope = scope.where("confidence >= ?", @min_confidence) unless show_weak_matches?
    scope = scope.where(provider: @provider) if @provider

    @candidates = scope.page(params[:page]).per(30)

    @counts = PreviewEnrichmentCandidate
      .group(:status)
      .count

    @providers = PreviewEnrichmentCandidate
      .where.not(provider: [nil, ""])
      .distinct
      .order(:provider)
      .pluck(:provider)
  end

  def image
    require "net/http"
    require "uri"

    allowed_hosts = %w[
      images.cults3d.com
      fbi.cults3d.com
      dl.myminifactory.com
      dl2.myminifactory.com
      media.printables.com
      storage.googleapis.com
    ]

    uri = URI.parse(@candidate.image_url)

    unless uri.is_a?(URI::HTTP) && allowed_hosts.include?(uri.host&.downcase)
      return head :forbidden
    end

    response = fetch_candidate_image(uri, allowed_hosts)

    unless response.is_a?(Net::HTTPSuccess)
      return head :bad_gateway
    end

    content_type = response["content-type"].to_s.split(";").first.downcase

    allowed_types = %w[
      image/jpeg
      image/png
      image/webp
      image/gif
      image/avif
    ]

    unless allowed_types.include?(content_type)
      return head :unsupported_media_type
    end

    body = response.body.to_s

    return head :payload_too_large if body.bytesize > 6.megabytes

    expires_in 1.hour, public: false

    send_data(
      body,
      type: content_type,
      disposition: "inline",
      filename: "preview-candidate-#{@candidate.id}#{extension_for(content_type)}"
    )
  rescue URI::InvalidURIError,
         Net::OpenTimeout,
         Net::ReadTimeout,
         SocketError,
         IOError,
         SystemCallError
    head :bad_gateway
  end

  def approve
    require "stringio"

    @candidate.update!(
      status: "downloading",
      reviewed_at: Time.current
    )

    allowed_hosts = %w[
      images.cults3d.com
      fbi.cults3d.com
      dl.myminifactory.com
      dl2.myminifactory.com
      media.printables.com
      storage.googleapis.com
    ]

    allowed_types = %w[
      image/jpeg
      image/png
      image/webp
      image/gif
      image/avif
    ]

    uri = URI.parse(@candidate.image_url)

    unless uri.is_a?(URI::HTTP) &&
        allowed_hosts.include?(uri.host&.downcase)
      raise "Image host is not allowed"
    end

    response = fetch_candidate_image(
      uri,
      allowed_hosts
    )

    unless response.is_a?(Net::HTTPSuccess)
      raise "Remote image returned HTTP #{response.code}"
    end

    content_type = response["content-type"].to_s
      .split(";")
      .first
      .downcase

    unless allowed_types.include?(content_type)
      raise "Unsupported image type: #{content_type}"
    end

    bytes = response.body.to_s

    raise "Downloaded image is empty" if bytes.empty?
    raise "Downloaded image exceeds 6 MB" if bytes.bytesize > 6.megabytes

    extension = extension_for(content_type)

    provider = @candidate.provider
      .to_s
      .downcase
      .gsub(/[^a-z0-9]+/, "-")
      .gsub(/\A-|\-\z/, "")

    provider = "source" if provider.blank?

    filename = "preview-enrichment-#{provider}-#{@candidate.id}#{extension}"

    model = @candidate.model

    file = model.model_files.find_or_initialize_by(
      filename: filename
    )

    io = StringIO.new(bytes)
    io.binmode

    file.attachment_attacher.attach(
      io,
      storage: model.library.storage_key,
      metadata: {
        "filename" => filename,
        "mime_type" => content_type,
        "size" => bytes.bytesize
      }
    )

    file.save!

    model.update!(
      preview_file: file
    )

    # This model now has an approved real preview image.
    # Hide all other unreviewed suggestions for the same model
    # while preserving them for audit/history.
    PreviewEnrichmentCandidate
      .where(model_id: model.id, status: "pending")
      .where.not(id: @candidate.id)
      .update_all(
        status: "superseded",
        reviewed_at: Time.current,
        updated_at: Time.current
      )

    @candidate.update!(
      status: "imported",
      reviewed_at: Time.current,
      metadata: (@candidate.metadata || {}).merge(
        "imported_model_file_id" => file.id,
        "imported_filename" => filename,
        "imported_at" => Time.current.iso8601
      )
    )

    redirect_back(
      fallback_location: settings_preview_enrichment_candidates_path,
      notice: "Preview imported and set as model preview."
    )

  rescue => error
    Rails.logger.error(
      "Preview enrichment import failed candidate #{@candidate&.id}: "       "#{error.class}: #{error.message}"
    )

    if @candidate&.persisted?
      @candidate.update_columns(
        status: "failed",
        reviewed_at: Time.current,
        metadata: (@candidate.metadata || {}).merge(
          "import_error" => "#{error.class}: #{error.message}",
          "failed_at" => Time.current.iso8601
        )
      )
    end

    redirect_back(
      fallback_location: settings_preview_enrichment_candidates_path,
      alert: "Preview import failed: #{error.message}"
    )
  end

  def reject
    @candidate.update!(
      status: "rejected",
      reviewed_at: Time.current
    )

    redirect_back fallback_location: settings_preview_enrichment_candidates_path,
      notice: "Preview candidate rejected."
  end

  private

  def authorize_settings
    authorize :settings, :update?
  end

  def set_candidate
    @candidate = PreviewEnrichmentCandidate.find(params[:id])
    authorize @candidate, "#{action_name}?"
  end

  def fetch_candidate_image(uri, allowed_hosts, redirects_left = 3)
    raise URI::InvalidURIError if redirects_left < 0

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 MakerLibrary3D/1.0"
    request["Accept"] = "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8"

    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 5,
      read_timeout: 12
    ) do |http|
      http.request(request)
    end

    if response.is_a?(Net::HTTPRedirection)
      location = response["location"]
      raise URI::InvalidURIError if location.blank?

      redirected_uri = URI.join(uri.to_s, location)

      unless redirected_uri.is_a?(URI::HTTP) &&
          allowed_hosts.include?(redirected_uri.host&.downcase)
        raise URI::InvalidURIError
      end

      return fetch_candidate_image(
        redirected_uri,
        allowed_hosts,
        redirects_left - 1
      )
    end

    response
  end

  def extension_for(content_type)
    {
      "image/jpeg" => ".jpg",
      "image/png" => ".png",
      "image/webp" => ".webp",
      "image/gif" => ".gif",
      "image/avif" => ".avif"
    }.fetch(content_type, "")
  end

  def permitted_status
    value = params[:status].presence || "pending"

    return value if PreviewEnrichmentCandidate::STATUSES.include?(value)

    "pending"
  end

  def minimum_confidence
    value = params[:min_confidence].presence || DEFAULT_MIN_CONFIDENCE
    value.to_i.clamp(0, 100)
  end

  def show_weak_matches?
    params[:show_weak] == "1"
  end
end
