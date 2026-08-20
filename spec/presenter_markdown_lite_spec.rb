# frozen_string_literal: true

require 'spec_helper'
require_relative '../web/lib/tyrion_web/presenter'

RSpec.describe 'TyrionWeb::Presenter.markdown_lite' do
  it 'escapes HTML before adding any markup' do
    expect(TyrionWeb::Presenter.markdown_lite('<script>alert(1)</script>'))
      .to eq('<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>')
  end

  it 'renders bold, italic, and inline code' do
    html = TyrionWeb::Presenter.markdown_lite('**bold** and *italic* and `code`')
    expect(html).to include('<strong>bold</strong>')
    expect(html).to include('<em>italic</em>')
    expect(html).to include('<code>code</code>')
  end

  it 'protects code span contents from the bold/italic passes' do
    html = TyrionWeb::Presenter.markdown_lite('use `*.rb` and `*.js` globs')
    expect(html).to include('<code>*.rb</code>')
    expect(html).to include('<code>*.js</code>')
    expect(html).not_to include('<em>')
  end

  it 'splits blank-line-separated text into paragraphs and single newlines into <br>' do
    html = TyrionWeb::Presenter.markdown_lite("first\nline one\n\nsecond para")
    expect(html).to eq('<p>first<br>line one</p><p>second para</p>')
  end

  it 'returns an empty string for nil or blank input' do
    expect(TyrionWeb::Presenter.markdown_lite(nil)).to eq('')
    expect(TyrionWeb::Presenter.markdown_lite('   ')).to eq('')
  end

  it 'renders a block of bullet lines as a ul/li list' do
    html = TyrionWeb::Presenter.markdown_lite("- first item\n- second item\n- third item")
    expect(html).to eq('<ul><li>first item</li><li>second item</li><li>third item</li></ul>')
  end

  it 'accepts * as a bullet marker too' do
    html = TyrionWeb::Presenter.markdown_lite("* one\n* two")
    expect(html).to eq('<ul><li>one</li><li>two</li></ul>')
  end

  it 'renders bold and inline code inside list items' do
    html = TyrionWeb::Presenter.markdown_lite("- **bold** item\n- has `code` in it")
    expect(html).to include('<li><strong>bold</strong> item</li>')
    expect(html).to include('<li>has <code>code</code> in it</li>')
  end

  it 'does not treat a block with mixed prose and bullets as a list' do
    html = TyrionWeb::Presenter.markdown_lite("intro line\n- not a list because of the line above")
    expect(html).not_to include('<ul>')
    expect(html).to include('<br>')
  end

  it 'renders a separate list block alongside a paragraph block' do
    html = TyrionWeb::Presenter.markdown_lite("intro paragraph\n\n- item one\n- item two")
    expect(html).to eq('<p>intro paragraph</p><ul><li>item one</li><li>item two</li></ul>')
  end
end
