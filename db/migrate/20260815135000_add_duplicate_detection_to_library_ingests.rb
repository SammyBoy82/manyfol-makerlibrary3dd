class AddDuplicateDetectionToLibraryIngests < ActiveRecord::Migration[8.0]
  def change
    add_column :library_ingests,
      :source_digest,
      :string

    add_column :library_ingests,
      :duplicate_status,
      :string,
      null: false,
      default: "unchecked"

    add_reference :library_ingests,
      :duplicate_model_file,
      foreign_key: {
        to_table: :model_files
      },
      null: true

    add_column :library_ingests,
      :duplicate_override,
      :boolean,
      null: false,
      default: false

    add_index :library_ingests,
      :source_digest

    add_index :library_ingests,
      :duplicate_status
  end
end
