require "http/client"
require "./spec_helper"
require "../src/data_layer_example_http"

private def call_data_layer_app(
  app : LF::HTTP::App,
  method : String,
  path : String,
  body : String? = nil,
) : HTTP::Client::Response
  io = IO::Memory.new
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  request = HTTP::Request.new(method, path, headers, body)
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))

  app.call(context)
  context.response.close
  HTTP::Client::Response.from_io(IO::Memory.new(io.to_s))
end

describe "data layer HTTP example" do
  it "serves health and persists projects through the data layer" do
    DataLayerExampleSpecSupport.with_store do |store|
      app = DataLayerExample::Web.build_app(store)

      health = call_data_layer_app(app, "GET", "/health")
      health.status.should eq(HTTP::Status::OK)
      JSON.parse(health.body)["status"].as_s.should eq("ok")

      created = call_data_layer_app(
        app,
        "POST",
        "/projects",
        %({"name":"http showcase"})
      )
      created.status.should eq(HTTP::Status::OK)
      project_id = JSON.parse(created.body)["id"].as_i64

      duplicate = call_data_layer_app(
        app,
        "POST",
        "/projects",
        %({"name":"http showcase"})
      )
      duplicate.status.should eq(HTTP::Status::CONFLICT)

      listed = call_data_layer_app(app, "GET", "/projects")
      listed.status.should eq(HTTP::Status::OK)
      projects = JSON.parse(listed.body)["projects"].as_a
      projects.size.should eq(1)
      projects.first["id"].as_i64.should eq(project_id)
      projects.first["name"].as_s.should eq("http showcase")
    end
  end

  it "supports task create, update, delete, and related queries" do
    DataLayerExampleSpecSupport.with_store do |store|
      app = DataLayerExample::Web.build_app(store)
      project = call_data_layer_app(app, "POST", "/projects", %({"name":"tasks"}))
      project_id = JSON.parse(project.body)["id"].as_i64

      created = call_data_layer_app(
        app,
        "POST",
        "/projects/#{project_id}/tasks",
        %({"title":"ship HTTP example"})
      )
      created.status.should eq(HTTP::Status::OK)
      created_task = JSON.parse(created.body)
      task_id = created_task["id"].as_i64
      created_task["completed"].as_bool.should be_false
      created_task["version"].as_i64.should eq(0_i64)

      store.source.transaction do |manager|
        task = manager.find(DataLayerExample::Task, task_id).not_nil!
        manager.persist(DataLayerExample::TaskEvent.new(task, "http-created"))
      end

      updated = call_data_layer_app(
        app,
        "PATCH",
        "/tasks/#{task_id}",
        %({"completed":true,"title":"ship the HTTP example"})
      )
      updated.status.should eq(HTTP::Status::OK)
      updated_task = JSON.parse(updated.body)
      updated_task["title"].as_s.should eq("ship the HTTP example")
      updated_task["completed"].as_bool.should be_true
      updated_task["version"].as_i64.should eq(1_i64)

      reverted = call_data_layer_app(
        app,
        "PATCH",
        "/tasks/#{task_id}",
        %({"completed":false})
      )
      reverted.status.should eq(HTTP::Status::OK)
      JSON.parse(reverted.body)["completed"].as_bool.should be_false

      empty_update = call_data_layer_app(app, "PATCH", "/tasks/#{task_id}", %({}))
      empty_update.status.should eq(HTTP::Status::BAD_REQUEST)

      listed = call_data_layer_app(app, "GET", "/projects/#{project_id}/tasks")
      JSON.parse(listed.body)["tasks"].as_a.size.should eq(1)

      deleted = call_data_layer_app(app, "DELETE", "/tasks/#{task_id}")
      deleted.status.should eq(HTTP::Status::OK)
      deleted.body.should eq("deleted")

      store.source.transaction do |manager|
        manager.query(DataLayerExample::TaskEvent).count.should eq(0_i64)
      end

      empty = call_data_layer_app(app, "GET", "/projects/#{project_id}/tasks")
      JSON.parse(empty.body)["tasks"].as_a.should be_empty
    end
  end

  it "returns HTTP errors for invalid input and missing records" do
    DataLayerExampleSpecSupport.with_store do |store|
      app = DataLayerExample::Web.build_app(store)

      invalid = call_data_layer_app(app, "POST", "/projects", "not json")
      invalid.status.should eq(HTTP::Status::BAD_REQUEST)

      missing_project = call_data_layer_app(
        app,
        "POST",
        "/projects/999/tasks",
        %({"title":"orphan"})
      )
      missing_project.status.should eq(HTTP::Status::NOT_FOUND)

      missing_task = call_data_layer_app(app, "PATCH", "/tasks/999", %({"completed":true}))
      missing_task.status.should eq(HTTP::Status::NOT_FOUND)
    end
  end
end
