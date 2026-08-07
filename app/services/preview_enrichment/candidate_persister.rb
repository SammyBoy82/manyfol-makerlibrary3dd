require "digest"

module PreviewEnrichment
  class CandidatePersister
    def initialize(model)
      @model = model
    end

    def persist(candidates)
      candidates.filter_map do |candidate|
        next if candidate.image_url.blank?

        fingerprint = Digest::SHA256.hexdigest(candidate.image_url)

        record = PreviewEnrichmentCandidate.find_or_initialize_by(
          model: model,
          fingerprint: fingerprint
        )

        # Never resurrect an explicitly rejected candidate.
        next if record.persisted? && record.status == "rejected"

        record.assign_attributes(
          image_url: candidate.image_url,
          source_page_url: candidate.source_page_url,
          source_domain: source_domain(candidate.source_page_url),
          provider: candidate.provider,
          match_method: candidate.match_method,
          confidence: candidate.confidence,
          metadata: candidate.metadata || {},
          discovered_at: Time.current
        )

        record.save!
        record
      end
    end

    private

    attr_reader :model

    def source_domain(url)
      return if url.blank?

      URI.parse(url).host
    rescue URI::InvalidURIError
      nil
    end
  end
end
