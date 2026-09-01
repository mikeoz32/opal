require "../http/router"

module LF::UI
  STYLESHEET_PATH = "/_opal/ui.css"
  STYLESHEET      = {{ read_file("#{__DIR__}/../../../assets/opal_ui.css") }}

  def stylesheet : String
    STYLESHEET
  end

  # Embeds the precompiled theme. Pass a CSP nonce when inline styles are
  # restricted by the application policy.
  def stylesheet_tag(nonce : String? = nil) : LF::LiveView::HTML::Safe
    markup = String.build do |html|
      html << "<style data-opal-ui-theme"
      if nonce
        html << %( nonce=") << LF::LiveView::HTML.escape(nonce) << '"'
      end
      html << '>' << STYLESHEET << "</style>"
    end
    LF::LiveView::HTML.raw(markup)
  end

  def stylesheet_link(path : String = STYLESHEET_PATH) : LF::LiveView::HTML::Safe
    validate_href!(path)
    markup = %(<link rel="stylesheet" href="#{LF::LiveView::HTML.escape(path)}" data-opal-ui-theme>)
    LF::LiveView::HTML.raw(markup)
  end

  # Registers a cacheable stylesheet route for applications that prefer a
  # linked asset over `stylesheet_tag`.
  def mount_assets(router : LF::HTTP::Router, path : String = STYLESHEET_PATH) : Nil
    unless path.starts_with?('/')
      raise ArgumentError.new("UI stylesheet route must be an absolute path")
    end
    router.get(path) do |context, _params|
      context.response.content_type = "text/css; charset=utf-8"
      context.response.headers["Cache-Control"] = "public, max-age=3600"
      context.response.print STYLESHEET
    end
  end
end
