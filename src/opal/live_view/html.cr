require "./rendered"

module LF::LiveView::HTML
  extend self

  # Explicitly marks trusted markup for interpolation into a structured
  # template. Prefer normal values, which are escaped automatically.
  struct Safe
    getter value : String

    def initialize(@value)
    end
  end

  def escape(value) : String
    String.build do |output|
      value.to_s.each_char do |char|
        case char
        when '&'  then output << "&amp;"
        when '<'  then output << "&lt;"
        when '>'  then output << "&gt;"
        when '"'  then output << "&quot;"
        when '\'' then output << "&#39;"
        else           output << char
        end
      end
    end
  end

  def raw(value : String) : Safe
    Safe.new(value)
  end

  def dynamic(value : Safe) : String
    value.value
  end

  def dynamic(value : LF::LiveView::Rendered) : LF::LiveView::RenderedDynamic
    value.component_content? || value.to_html
  end

  def dynamic(value : LF::LiveView::StreamContent) : LF::LiveView::StreamContent
    value
  end

  def dynamic(value : LF::LiveView::ComponentContent) : LF::LiveView::ComponentContent
    value
  end

  def dynamic(value : LF::LiveView::KeyedContent) : LF::LiveView::KeyedContent
    value
  end

  def dynamic(value : LF::LiveView::ChildViewContent) : LF::LiveView::ChildViewContent
    value
  end

  def dynamic(value) : String
    escape(value)
  end

  # Renders a collection as an upstream Phoenix keyed comprehension. The block
  # returns a stable key and one structured render using the same static
  # template for every entry.
  #
  #     rows = HTML.keyed(projects) do |project|
  #       {project.id, HTML.rendered(%(<li id="project-#{project.id}">#{project.name}</li>))}
  #     end
  def keyed(items, &block) : LF::LiveView::KeyedContent
    entries = [] of LF::LiveView::KeyedEntry
    items.each do |item|
      key, rendered = yield item
      entries << LF::LiveView::KeyedEntry.new(key.inspect, rendered)
    end
    LF::LiveView::KeyedContent.new(entries)
  end

  # Compiles an interpolated Crystal string into a structural LiveView render.
  # Literal fragments form a stable template fingerprint; interpolations become
  # independently diffable, HTML-escaped dynamic positions.
  macro rendered(value)
    {% statics = [] of ASTNode %}
    {% dynamics = [] of ASTNode %}
    {% if value.is_a?(StringLiteral) %}
      {% statics << value %}
    {% elsif value.is_a?(StringInterpolation) %}
      {% for expression in value.expressions %}
        {% if expression.is_a?(StringLiteral) %}
          {% statics << expression %}
        {% else %}
          {% if statics.size == dynamics.size %}
            {% statics << "" %}
          {% end %}
          {% dynamics << expression %}
        {% end %}
      {% end %}
      {% if statics.size == dynamics.size %}
        {% statics << "" %}
      {% end %}
    {% else %}
      {% raise "LF::LiveView::HTML.rendered expects a string literal or heredoc" %}
    {% end %}

    LF::LiveView::Rendered.new(
      [
        {% for static in statics %}
          {{ static }},
        {% end %}
      ] of String,
      [
        {% for dynamic in dynamics %}
          LF::LiveView::HTML.dynamic({{ dynamic }}),
        {% end %}
      ] of LF::LiveView::RenderedDynamic
    )
  end
end
