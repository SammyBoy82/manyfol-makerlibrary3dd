class AddMembershipLifecycleToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users,
      :membership_status,
      :string,
      null: false,
      default: "active"

    add_column :users,
      :membership_started_at,
      :datetime

    add_column :users,
      :membership_expires_at,
      :datetime

    add_column :users,
      :membership_admin_notes,
      :text

    add_index :users,
      :membership_status

    add_index :users,
      :membership_expires_at
  end
end
