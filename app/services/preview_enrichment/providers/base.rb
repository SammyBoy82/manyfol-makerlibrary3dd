module PreviewEnrichment
  module Providers
    class Base
      Candidate = Struct.new(
        :provider,
        :source_page_url,
        :image_url,
        :title,
        :creator,
        :license,
        :confidence,
        :match_method,
        :metadata,
        keyword_init: true
      )

      def initialize(model)
        @model = model
      end

      def search
        raise NotImplementedError
      end

      private

      attr_reader :model
    end
  end
end
