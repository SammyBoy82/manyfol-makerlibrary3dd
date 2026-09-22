class AddUploadTrackingToLibraryIngests < ActiveRecord::Migration[8.0]
  def change
    add_reference :library_ingests,
      :model,
      foreign_key: true,
      null: true

    add_reference :library_ingests,
      :model_file,
      foreign_key: true,
      null: true

    add_column :library_ingests,
      :source_origin,
      :string,
      null: false,
      default: "filesystem"

    add_index :library_ingests,
      :source_origin
  end
end
