# frozen_string_literal: true
require 'rails_helper'
require 'csv'

RSpec.describe Importer do
  subject(:importer) { described_class.new(parser: parser) }
  let(:file) { File.open('spec/fixtures/example.csv') }
  let(:parser) { IrisCsvParser.new(file: file) }

  it "can create an Importer" do
    expect(importer).to be_instance_of described_class
  end

  it "inherits from the Darlingtonia Importer" do
    expect(described_class).to be < Darlingtonia::Importer
  end

  it "uses the IrisCsvParser" do
    expect(importer.parser.class).to eq IrisCsvParser
  end

  it "importing a record queues jobs to update the GeoBlacklight app" do
    expect { importer.import }.to change { ImageWork.count }.by 1
    expect(ImageWork.count).to eq 1
    image = ImageWork.first

    expect(GeoblacklightJob).to have_been_enqueued.with(
      'id' => image.id,
      'event' => 'CREATED',
      'doc' => hash_including(dc_identifier_s: image.id)
    )
    # TODO: Jobs should also queue for attached files
  end

  describe 'Generated URLs' do
    let(:image) { ImageWork.first }

    let(:expected_reference) { "{\"http://schema.org/url\":\"#{expected_protocol}#{ENV['RAILS_HOST']}/concern/image_works/#{image.id}\"}" }

    before do
      allow(Rails.application.config).to receive(:force_ssl).and_return(ssl_config)
      importer.import
      expect(ImageWork.count).to eq 1
      image # Find the newly-created ImageWork
    end

    context 'When SSL is configured' do
      let(:ssl_config) { true }
      let(:expected_protocol) { 'https://' }

      it 'configures URL with https' do
        expect(GeoblacklightJob).to have_been_enqueued.with(
          hash_including('doc' => hash_including(dct_references_s: expected_reference))
        )
      end
    end

    context 'When SSL is not configured' do
      let(:ssl_config) { false }
      let(:expected_protocol) { 'http://' }

      it 'configures URL with http' do
        expect(GeoblacklightJob).to have_been_enqueued.with(
          hash_including('doc' => hash_including(dct_references_s: expected_reference))
        )
      end
    end
  end

  it "creates an ImageWork from a one-row csv" do
    expect { importer.import }.to change { ImageWork.count }.by 1
    expect(ImageWork.count).to eq 1
    image = ImageWork.first

    expect(image.visibility).to eq "open"
  end

  context "a CSV without 'visibility' field" do
    let(:file) { File.open(File.join(fixture_path, "example_with_no_visibility.csv")) }

    it "creates a work with 'restricted' visibility" do
      expect { importer.import }.to change { ImageWork.count }.by 1
      expect(ImageWork.count).to eq 1
      image = ImageWork.first

      expect(image.visibility).to eq "restricted"
    end
  end

  context 'creates a RasterWork and then attaches a geo tif file' do
    let(:file) { File.open(File.join(fixture_path, "raster_example.csv")) }
    let(:raster_title) do
      data = CSV.read(File.join(fixture_path, "raster_example.csv"), headers: true)
      data['file_name'].first
    end

    it 'attaches file as a FileSet and sets its representative title to file_name', :perform_enqueued do
      ActiveJob::Base.queue_adapter.filter = [IngestFileJob]

      importer.import
      raster_work = RasterWork.where(title: 'Great Rasters')

      expect(FileSet.find(raster_work.first.representative_id).title.first).to eql(raster_title)
    end

    it "creates a thumbnail", :perform_enqueued do
      ActiveJob::Base.queue_adapter.filter = [IngestFileJob]

      importer.import
      raster_work = RasterWork.where(title: 'Great Rasters')

      expect(FileSet.find(raster_work.first.representative_id).thumbnail_id).not_to be_empty
    end

    it "adds file_set information to the work's index", :perform_enqueued do
      ActiveJob::Base.queue_adapter.filter = [IngestFileJob]

      importer.import
      raster_work = RasterWork.where(title: 'Great Rasters')

      expect(raster_work.first.to_solr["file_set_ids_ssim"]).not_to be_empty
    end
  end

  # TODO: test for specific properties of geo files: spatial, temporal, coverage, etc.
  # See https://github.com/samvera-labs/geo_works/blob/master/spec/services/geo_works/discovery/document_builder_spec.rb for reference.
  context "creates a VectorWork and attaches shape files" do
    let(:file) { File.open(File.join(fixture_path, "vector_example.csv")) }
    let(:vector_title) do
      data = CSV.read(File.join(fixture_path, "vector_example.csv"), headers: true)
      data['shape_file'].first
    end

    it "attaches and indexes the shape file set as a FileSet", :perform_enqueued do
      ActiveJob::Base.queue_adapter.filter = [IngestFileJob]
      importer.import
      vector_work = VectorWork.where(title: 'Victor Vector')

      expect(vector_work.first.to_solr["file_set_ids_ssim"].size).to eq(1)
    end

    it 'creates and indexes a .png thumbnail', :perform_enqueued do
      ActiveJob::Base.queue_adapter.filter = [IngestFileJob]

      importer.import
      vector_work = VectorWork.where(title: 'Victor Vector')

      expect(FileSet.find(vector_work.first.representative_id).to_solr['thumbnail_path_ss']).to include('.png')
    end

    it "sets the thumbnail title to the shape_file name", :perform_enqueued do
      ActiveJob::Base.queue_adapter.filter = [IngestFileJob]

      importer.import
      vector_work = VectorWork.where(title: 'Victor Vector')

      expect(FileSet.find(vector_work.first.representative_id).title.first).to eql(vector_title)
    end
  end
end
