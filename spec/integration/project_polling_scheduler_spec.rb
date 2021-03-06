require 'spec_helper'

describe ProjectPollingScheduler do

  subject { ProjectPollingScheduler.new }

  describe '#run_once' do
    before do
      Project.delete_all
    end

    it 'should update ci projects (even when there are no projects with tracker integrations)' do
      create(:jenkins_project)

      stub_request(:get, 'http://www.example.com/job/project/rssAll')
          .to_return(body: File.new('spec/fixtures/jenkins_atom_examples/success.atom'), status: 200)
      stub_request(:get, 'http://www.example.com/cc.xml')
          .to_return(body: File.new('spec/fixtures/jenkins_atom_examples/jenkins_projectmonitor_not_building.atom'), status: 200)

      expect {
        subject.run_once
      }.to change { PayloadLogEntry.count }.by 1

      expect(PayloadLogEntry.last.status).to eq('successful')
    end

    it 'should gracefully handle ci projects that fail to update successfully' do
      create(:jenkins_project)

      stub_request(:get, 'http://www.example.com/job/project/rssAll')
          .to_return(body: File.new('spec/fixtures/jenkins_atom_examples/invalid_xml.atom'), status: 200)
      stub_request(:get, 'http://www.example.com/cc.xml')
          .to_return(body: File.new('spec/fixtures/jenkins_atom_examples/invalid_xml.atom'), status: 200)

      expect {
        subject.run_once
      }.to change { PayloadLogEntry.count }.by 1

      expect(PayloadLogEntry.last.status).to eq('failed')
    end

    it 'should update tracker projects' do
      project = create(:project_with_tracker_integration, tracker_project_id: '2872', tracker_auth_token: 'secret-tracker-api-key')
      project.update_attributes(ci_base_url: 'https://jenkins.mono-project.com', ci_build_identifier: 'test-gtksharp-mainline-2.12')

      VCR.use_cassette('poller_tracker_run_once') do
        subject.run_once
      end

      p = Project.find(project.id)
      expect(p.current_velocity).to eq(1)
      expect(p.last_ten_velocities).to eq([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
      expect(p.iteration_story_state_counts).to eq [{'label' => 'unstarted', 'value' => 0},
                                                    {'label' => 'started', 'value' => 8},
                                                    {'label' => 'finished', 'value' => 0},
                                                    {'label' => 'delivered', 'value' => 0},
                                                    {'label' => 'accepted', 'value' => 0},
                                                    {'label' => 'rejected', 'value' => 0}]
      expect(p.tracker_online).to eq(true)
    end

    it 'should update concourse (V2) projects' do
      PayloadLogEntry.delete_all

      project = create(:concourse_project)
      project.update_attributes(
          ci_base_url: 'https://jetway.pivotal.io',
          ci_build_identifier: 'build',
          concourse_pipeline_name: 'augur-production',
          auth_username: 'user',
          auth_password: 'pass'
      )

      # This cassette was manually modified to remove the actual credentials and session token and
      # replace them with fixture values
      VCR.use_cassette('poller_concourse_run_once') do
        subject.run_once
      end

      expect(PayloadLogEntry.count).to eq(1)
      expect(PayloadLogEntry.last.status).to eq('successful')
    end

    it 'should exit gracefully when there are no projects' do
      Project.delete_all

      subject.run_once

      expect(true).to eq(true)
    end
  end
end
