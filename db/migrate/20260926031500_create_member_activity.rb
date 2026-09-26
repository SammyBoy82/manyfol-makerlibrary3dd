class CreateMemberActivity < ActiveRecord::Migration[8.0]
  def change
    create_table :model_views do |t|
      t.references :user, null: false, foreign_key: {on_delete: :cascade}
      t.references :model, null: false, foreign_key: {on_delete: :cascade}
      t.datetime :last_viewed_at, null: false
      t.integer :view_count, null: false, default: 1

      t.timestamps
    end

    add_index :model_views, [:user_id, :model_id], unique: true
    add_index :model_views, [:user_id, :last_viewed_at]

    create_table :download_events do |t|
      t.references :user, null: false, foreign_key: {on_delete: :cascade}
      t.references :model, null: false, foreign_key: {on_delete: :cascade}
      t.references :model_file, null: true, foreign_key: {on_delete: :nullify}
      t.string :selection, null: false, default: "all", limit: 64
      t.datetime :downloaded_at, null: false

      t.timestamps
    end

    add_index :download_events, [:user_id, :downloaded_at]
    add_index :download_events, [:user_id, :model_id]
  end
end
