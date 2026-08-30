require "./spec_helper"
require "../../src/opal/data"

class MetadataTodo
  include LF::Data::Entity

  @[LF::Data::Id(generated: true)]
  getter id : Int64?

  @[LF::Data::Column(name: "summary")]
  getter title : String

  getter details : String?

  @[LF::Data::Column(ignore: true)]
  getter display_label : Array(String) = [] of String

  @[LF::Data::Version]
  getter lock_version : Int64 = 0_i64

  def initialize(@title : String, @details : String? = nil)
    @id = nil
  end
end

class HTTPAuditLog
  include LF::Data::Entity

  @[LF::Data::Id]
  getter id : Int64

  def initialize(@id : Int64)
  end
end

module MetadataNamespace
  @[LF::Data::Table(name: "audit_records")]
  class AuditEvent
    include LF::Data::Entity

    @[LF::Data::Id]
    @[LF::Data::Column(name: "event_key")]
    getter id : String

    def initialize(@id : String)
    end
  end
end

describe LF::Data::Entity do
  it "generates deterministic table and column names in declaration order" do
    MetadataTodo.__lf_table_name.should eq("metadata_todo")
    MetadataTodo.__lf_persistent_columns.should eq({
      "id",
      "summary",
      "details",
      "lock_version",
    })
  end

  it "generates ID and version metadata" do
    MetadataTodo.__lf_id_column.should eq("id")
    MetadataTodo.__lf_id_type.should eq(Int64)
    MetadataTodo.__lf_generated_id?.should be_true
    MetadataTodo.__lf_version_column.should eq("lock_version")
  end

  it "uses the same acronym-aware snake-case convention as DI" do
    HTTPAuditLog.__lf_table_name.should eq("http_audit_log")
  end

  it "uses the unqualified name and honors explicit mapping names" do
    MetadataNamespace::AuditEvent.__lf_table_name.should eq("audit_records")
    MetadataNamespace::AuditEvent.__lf_persistent_columns.should eq({"event_key"})
    MetadataNamespace::AuditEvent.__lf_id_column.should eq("event_key")
    MetadataNamespace::AuditEvent.__lf_id_type.should eq(String)
    MetadataNamespace::AuditEvent.__lf_generated_id?.should be_false
    MetadataNamespace::AuditEvent.__lf_version_column.should be_nil
  end
end
