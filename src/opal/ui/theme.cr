require "../http/router"

module LF::UI
  STYLESHEET_PATH = "/_opal/ui.css"
  STYLESHEET      = {{ read_file("#{__DIR__}/../../../assets/opal_ui.css") }}
  HOOKS_PATH      = "/_opal/ui.js"
  HOOKS           = {{ read_file("#{__DIR__}/../../../assets/opal_ui.js") }}

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

  def hooks : String
    HOOKS
  end

  # Registers Opal's optional UI hooks before the LiveView client module loads.
  def hook_script_tag(nonce : String? = nil) : LF::LiveView::HTML::Safe
    markup = String.build do |html|
      html << "<script data-opal-ui-hooks"
      if nonce
        html << %( nonce=") << LF::LiveView::HTML.escape(nonce) << '"'
      end
      html << '>' << HOOKS.gsub("</script", "<\\/script") << "</script>"
    end
    LF::LiveView::HTML.raw(markup)
  end

  def hook_script_link(path : String = HOOKS_PATH) : LF::LiveView::HTML::Safe
    validate_href!(path)
    markup = %(<script src="#{LF::LiveView::HTML.escape(path)}" data-opal-ui-hooks></script>)
    LF::LiveView::HTML.raw(markup)
  end

  # Registers cacheable stylesheet and browser-hook routes for applications
  # that prefer linked assets over inline tags.
  def mount_assets(
    router : LF::HTTP::Router,
    path : String = STYLESHEET_PATH,
    hooks_path : String = HOOKS_PATH,
  ) : Nil
    unless path.starts_with?('/')
      raise ArgumentError.new("UI stylesheet route must be an absolute path")
    end
    unless hooks_path.starts_with?('/')
      raise ArgumentError.new("UI hooks route must be an absolute path")
    end
    if path == hooks_path
      raise ArgumentError.new("UI stylesheet and hooks routes must be different")
    end
    router.get(path) do |context, _params|
      context.response.content_type = "text/css; charset=utf-8"
      context.response.headers["Cache-Control"] = "public, max-age=3600"
      context.response.print STYLESHEET
    end
    router.get(hooks_path) do |context, _params|
      context.response.content_type = "text/javascript; charset=utf-8"
      context.response.headers["Cache-Control"] = "public, max-age=3600"
      context.response.print HOOKS
    end
  end
end
