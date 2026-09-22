class CreateAdminAuditEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :admin_audit_events do |t|
      t.bigint :actor_id
      t.string :actor_name, null: false
      t.string :action, null: false

      t.string :target_type
      t.bigint :target_id
      t.string :target_name

      t.string :ip_address
      t.json :before_data, null: false, default: {}
      t.json :after_data, null: false, default: {}
      t.json :context, null: false, default: {}

      t.timestamps
    end

    add_index :admin_audit_events, :actor_id
    add_index :admin_audit_events, :action
    add_index :admin_audit_events, :created_at
    add_index :admin_audit_events,
      [:target_type, :target_id],
      name: "idx_admin_audit_target"
  end
end
