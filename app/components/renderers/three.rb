# frozen_string_literal: true

module Components::Renderers
  class Three < Components::Renderers::Base
    include Phlex::Rails::Helpers::NumberToHumanSize

    register_value_helper :vite_asset_url

    def self.supports?(file)
      FileHandlers::Three.can_load? file&.mime_type
    end

    def before_template
      @settings =
        current_user&.renderer_settings ||
        SiteSettings::UserDefaults::RENDERER

      # MakerLibrary3D:
      # A missing persistent preview should repair itself.
      #
      # First visit:
      #   browser may render interactively
      #   +
      #   server queues a permanent render
      #
      # Later visits:
      #   persistent :render derivative is reused.
      unless @file.has_render?
        PreviewRendering::EnsureRenderJob.perform_later(@file.id)
      end
    end

    def view_template
      if @file.has_render?
        persistent_render
      else
        interactive_renderer
      end
    end

    private

    #
    # IMPORTANT:
    #
    # If Manyfold already has a server-generated F3D render,
    # use that persistent derivative directly.
    #
    # Do NOT initialize Three.js and do NOT download/parse the
    # original STL/OBJ/3MF again simply because the page opened.
    #
    def persistent_render
      div class: "position-relative" do

        img(
          src: model_model_file_path(
            @file.model,
            @file,
            format: @file.extension,
            derivative: :render
          ),
          class: "card-img-top image-preview",
          alt: @file.name,
          loading: "lazy"
        )

        div(
          class:
            "position-absolute bottom-0 end-0 m-2 " \
            "badge text-bg-dark opacity-75"
        ) do
          span { "Cached 3D Preview" }
        end

      end
    end

    #
    # Only files WITHOUT a persistent render use the interactive
    # client-side renderer.
    #
    def interactive_renderer
      div(
        class: "position-relative"
      ) do

        canvas(
          id: "preview-file-#{@file.to_param}",
          class: "object-preview position-relative",
          tabindex: "0",
          data: {
            controller: "renderer",
            preview_url:
              model_model_file_raw_path(
                @file.model,
                @file.filename
              ),
            worker_url:
              vite_asset_url(
                "offscreen_renderer.ts"
              ),
            format: @file.extension,
            y_up: @file.y_up.to_s,
            grid_size_x:
              @settings["grid_width"],
            grid_size_z:
              @settings["grid_depth"],
            show_grid:
              @settings["show_grid"].to_s,
            enable_pan_zoom:
              @settings["enable_pan_zoom"].to_s,
            background_colour:
              @settings["background_colour"],
            object_colour:
              @settings["object_colour"],
            render_style:
              @settings["render_style"],
            # MakerLibrary3D:
            # Automatically display normal-size models on the
            # first visit while the server generates the reusable
            # persistent render in the background.
            #
            # Very large files remain manual to reduce browser OOM
            # risk.
            auto_load:
              (@file.size.to_i <= 100.megabytes) ? "true" : "false"
          }
        )

        div(
          class:
            "p-0 btn btn-secondary " \
            "load-progress object-preview-progress " \
            "position-absolute start-50 " \
            "top-50 translate-middle",
          role: "presentation"
        ) do

          div(
            class:
              "progress-bar bg-info " \
              "progress-bar-animated " \
              "progress-bar-striped",
            role: "progressbar",
            style:
              "width: 0%; height: 100%",
            aria_label:
              "Loading progress",
            aria_valuenow: "0",
            aria_valuemin: "0",
            aria_valuemax: "100"
          )

          span(
            class:
              "progress-label position-absolute " \
              "top-50 start-50 translate-middle",
            role: "button"
          ) do
            Icon icon: "box"
            whitespace
            span { t("renderer.load") }
            whitespace
            span do
              size_label =
                number_to_human_size(
                  @file.size,
                  precision: 2
                )

              if @file.size.to_i > 100.megabytes
                "(#{size_label} - Large model)"
              else
                "(#{size_label})"
              end
            end
          end

        end
      end
    end
  end
end
