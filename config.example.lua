local config = {
    -- Your email credentials
    email = "your_email@gmail.com",
    password = "your_app_password",
    
    -- IMAP server settings (Defaults are for Gmail)
    imap_server = "imap.gmail.com",
    imap_port = 993,
    use_ssl = true,
    
    -- Where you want the books saved on your Kindle
    download_path = "/mnt/us/books/"
}

return config
