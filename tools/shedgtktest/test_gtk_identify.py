"""identify echoes the backend + hermeticity fields (core=rust, platform=gtk)."""


def test_identify_reports_gtk_core_and_hermeticity(gtk, mock):
    info = gtk.identify()
    assert info["core"] == "rust"
    assert info["platform"] == "gtk"
    assert info["test_mode"] is True
    assert info["mock_base_url"] == mock.base_url
    assert info["socket_path"].endswith("shed-gtk.sock")
