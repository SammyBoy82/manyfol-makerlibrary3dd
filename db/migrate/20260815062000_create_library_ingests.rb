class CreateLibraryIngests < ActiveRecord::Migration[8.0]
  def change
    create_table :library_ingests do |t|
      t.references :library,
        null: false,
        foreign_key: true

      t.string :source_path,
        null: false

      t.string :source_name,
        null: false

      t.string :source_type,
        null: false

      t.string :status,
        null: false,
        default: "pending"

      t.string :destination_path

      t.text :error_message

      t.datetime :started_at
      t.datetime :completed_at

      t.bigint :source_size

      t.timestamps
    end

    add_index :library_ingests,
      :status

    add_index :library_ingests,
      :created_at

    add_index :library_ingests,
      [:library_id, :source_path],
      unique: true,
      name: "idx_library_ingests_unique_source"
  end
end
