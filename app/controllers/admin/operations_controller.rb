require "sidekiq/api"

module Admin
  class OperationsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_administrator!

    def index
      skip_policy_scope
      skip_authorization
      @snapshot = Admin::OperationsSnapshot.call
    end

    def control_center
      skip_policy_scope
      skip_authorization
      @snapshot = Admin::OperationsSnapshot.call
    end

    def dead_jobs
      skip_policy_scope
      skip_authorization

      @jobs = Sidekiq::DeadSet.new.to_a.first(200)
    end

    def retry_dead_job
      skip_authorization

      job = Sidekiq::DeadSet.new.find_job(params[:jid])
      if job
        job.retry
        redirect_to admin_operations_dead_jobs_path, notice: "Dead job #{params[:jid]} queued for retry."
      else
        redirect_to admin_operations_dead_jobs_path, alert: "Dead job not found."
      end
    end

    def delete_dead_job
      skip_authorization

      job = Sidekiq::DeadSet.new.find_job(params[:jid])
      if job
        job.delete
        redirect_to admin_operations_dead_jobs_path, notice: "Dead job #{params[:jid]} deleted."
      else
        redirect_to admin_operations_dead_jobs_path, alert: "Dead job not found."
      end
    end

    def clear_dead_jobs
      skip_authorization

      count = Sidekiq::DeadSet.new.size
      Sidekiq::DeadSet.new.clear
      redirect_to admin_operations_dead_jobs_path, notice: "Cleared #{count} dead job(s)."
    end

    def problems
      skip_policy_scope
      skip_authorization

      @category = params[:category].to_s
      unless Problem.categories.key?(@category)
        redirect_to admin_operations_path, alert: "Unknown problem category."
        return
      end

      @problems = Problem.where(category: @category).order(created_at: :desc).limit(500)
    end

    private

    def require_administrator!
      return if current_user&.is_administrator?

      head :forbidden
    end
  end
end
