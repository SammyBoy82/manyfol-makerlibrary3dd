module PreviewEnrichment
  module Providers
    class MakerworldSearch < RepositorySearchBase
      HOST = "makerworld.com"

      private

      def provider_name
        "makerworld"
      end

      def search_repository(query)
        uri = URI("https://makerworld.com/en/search/models")
        uri.query = URI.encode_www_form(keyword: query)

        html = fetch_html(uri)

        return [] if html.blank?

        extract_results(html, uri.to_s, query)
      end

      def extract_results(html, search_url, query)
        results = []

        html.scan(
          /<a[^>]+href=["']([^"']*\/models\/[^"']+)["'][^>]*>(.*?)<\/a>/im
        ).each do |href, content|
          title = normalize(content)

          next if title.blank?

          url = URI.join("https://makerworld.com", href).to_s

          results << Candidate.new(
            provider: provider_name,
            source_page_url: url,
            image_url: nil,
            title: title,
            creator: nil,
            license: nil,
            confidence: confidence_for(title),
            match_method: "repository_title_search",
            metadata: {
              query: query,
              search_url: search_url
            }
          )
        end

        results
          .uniq { |candidate| candidate.source_page_url }
          .first(10)
      end

      def confidence_for(title)
        target = model.name.to_s.downcase
        result = title.to_s.downcase

        return 90 if result == target
        return 80 if result.include?(target) || target.include?(result)

        model_words = target.scan(/[a-z0-9]+/).uniq
        result_words = result.scan(/[a-z0-9]+/).uniq

        overlap = (model_words & result_words).count

        return 75 if overlap >= 3
        return 65 if overlap >= 2

        50
      end
    end
  end
end
