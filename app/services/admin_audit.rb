class AdminAudit
  def self.record(
    actor:,
    action:,
    target: nil,
    request: nil,
    before_data: {},
    after_data: {},
    context: {}
  )
    AdminAuditEvent.create!(
      actor_id: actor&.id,
      actor_name:
        actor&.username.presence ||
        actor&.email.presence ||
        "system",
      action: action,
      target_type:
        target&.class&.name,
      target_id:
        target&.id,
      target_name:
        display_name(target),
      ip_address:
        request&.remote_ip,
      before_data:
        clean(before_data),
      after_data:
        clean(after_data),
      context:
        clean(context)
    )
  rescue StandardError => e
    Rails.logger.error(
      "[AdminAudit] #{e.class}: #{e.message}"
    )

    nil
  end

  def self.display_name(target)
    return nil unless target

    if target.respond_to?(:username)
      target.username
    elsif target.respond_to?(:name)
      target.name
    else
      target.to_s
    end
  end

  def self.clean(value)
    JSON.parse(
      JSON.generate(value)
    )
  rescue StandardError
    {}
  end
end
