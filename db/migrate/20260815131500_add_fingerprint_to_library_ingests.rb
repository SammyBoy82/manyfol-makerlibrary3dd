class AddFingerprintToLibraryIngests < ActiveRecord::Migration[8.0]
  def change
    remove_index :library_ingests,
      name: "idx_library_ingests_unique_source"

    add_column :library_ingests,
      :source_fingerprint,
      :string

    add_index :library_ingests,
      [:library_id, :source_path, :source_fingerprint],
      unique: true,
      name: "idx_library_ingests_unique_source_fingerprint"
  end
end
