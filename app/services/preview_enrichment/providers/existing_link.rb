require "uri"

module PreviewEnrichment
  module Providers
    class ExistingLink < Base
      SUPPORTED_DOMAINS = {
        "thingiverse.com" => "thingiverse",
        "www.thingiverse.com" => "thingiverse",
        "cults3d.com" => "cults3d",
        "www.cults3d.com" => "cults3d",
        "myminifactory.com" => "myminifactory",
        "www.myminifactory.com" => "myminifactory"
      }.freeze

      def search
        model.links.filter_map do |link|
          build_candidate(link.url)
        rescue URI::InvalidURIError
          nil
        end
      end

      private

      def build_candidate(url)
        uri = URI.parse(url)
        provider = SUPPORTED_DOMAINS[uri.host&.downcase]

        return unless provider

        Candidate.new(
          provider: provider,
          source_page_url: url,
          image_url: nil,
          title: model.name,
          creator: model.creator&.name,
          confidence: 90,
          match_method: "existing_model_link",
          metadata: {
            source: "existing_link",
            host: uri.host
          }
        )
      end
    end
  end
end
