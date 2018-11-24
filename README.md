## Ena
Ena is a drop-in replacement for Asagi--created in Nim-lang. It is efficient and uses minimal amounts of RAM. 




## Installation
Install [nim](https://nim-lang.org/install.html) first, then run: ```nim build ena```

If you need PostgreSQL support instead of MySQL, run: ```nim build_postgres ena```

Vichan board support is available, but incomplete. 
To use this program on Vichan sites run: ```nim build_vichan ena``` or ```nim build_vichan_postgres ena```

```config.example.ini``` should then be renamed to ```config.ini``` and modified.


## Credits
Andrey - for the *SQL schema, functions and triggers used in Fuuka.

Tanami - for hosting an instance used for stress testing the program.
