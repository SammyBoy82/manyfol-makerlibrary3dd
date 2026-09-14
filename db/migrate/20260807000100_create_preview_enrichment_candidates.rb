class CreatePreviewEnrichmentCandidates < ActiveRecord::Migration[8.0]
  def change
    create_table :preview_enrichment_candidates do |t|
      t.references :model, null: false, foreign_key: true

      # Candidate image information
      t.text :image_url, null: false
      t.text :source_page_url
      t.string :source_domain
      t.string :provider

      # Discovery information
      t.text :search_query
      t.string :match_method
      t.integer :confidence

      # Workflow state
      t.string :status, null: false, default: "pending"

      # Used for deduplication without indexing very long URLs
      t.string :fingerprint, null: false

      # Additional provider-specific information
      t.json :metadata

      t.datetime :discovered_at
      t.datetime :reviewed_at

      t.timestamps
    end

    add_index :preview_enrichment_candidates,
      [:model_id, :fingerprint],
      unique: true,
      name: "idx_preview_candidates_model_fingerprint"

    add_index :preview_enrichment_candidates, :status
    add_index :preview_enrichment_candidates, :provider
  end
end
