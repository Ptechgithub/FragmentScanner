# FragmentScanner

## Install
```
bash <(curl -fsSL https://raw.githubusercontent.com/Ptechgithub/FragmentScanner/main/install.sh)
```
![28](https://raw.githubusercontent.com/Ptechgithub/configs/main/media/28.jpg)

- Supports protocols:
  - VLESS WS/GRPC
  - VMESS WS/GRPC
  - TROJAN WS/GRPC

By selecting option 1, you can provide your simple configuration (without fragment) to the script, and it will give you a custom output (in JSON format) with the fragment. You can copy and use this format as it is the prerequisite for option 2.

After adding the fragment and displaying your configuration in JSON format, it will be saved in the `config.json` file in the same directory. Now, you can scan for the appropriate fragment values using option 2. Just select option 2, and it will read the configuration file created in the previous step, ask you four questions, and then start scanning, displaying the results.

---
Question 1: Determines the number of scan rounds. The default is 10, meaning it tests 10 random combinations with the provided values.

Question 2: Sets the timeout duration for ping tests.

Question 3: Change the port only if you have modified the Listening port inside `config.json`. Otherwise, just press Enter.

Question 4: Enter the number of requests for each sample, i.e., how many times a set of values should be tested.

---

To ensure the output is displayed neatly and without code indentation issues, zoom out before running the script.

If you exit the program and want to display the `config.json` file again, enter the command `cat config.json` and press Enter.

You can also save your fragment configuration in the `config.json` file and just use option 2 to perform the scan.

Credits:
[Surfboardv2ray](https://github.com/Surfboardv2ray/batch-fragment-scanner)