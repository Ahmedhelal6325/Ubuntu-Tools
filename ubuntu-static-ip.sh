#!/bin/bash
#
# ubuntu-static-ip.sh
# طريقة التشغيل الصحيحة (مهم جداً):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Ahmedhelal6325/Ubuntu-Tools/main/ubuntu-static-ip.sh)"
#
# لا تستخدم صيغة الـ pipe العادية (curl | sudo bash) لأنها بتاخد الـ stdin
# وتمنع أوامر read من قراءة أي مدخلات، مما يسبب لوب لا نهائي.

set -u
MAX_ATTEMPTS=5

# تأكيد تشغيل الأسكربت بصلاحيات الـ Root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31m[!] من فضلك قم بتشغيل الأسكربت باستخدام sudo\e[0m"
  exit 1
fi

echo -e "\e[34m====================================================\e[0m"
echo -e "\e[32m     أسكربت إعداد الأي بي الثابت التفاعلي والمستقر    \e[0m"
echo -e "\e[34m====================================================\e[0m"

# فحص وجود تيرمينال تفاعلي فعلي (وإلا read هترجع فاضية دايماً)
if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
    echo -e "\e[31m[!] لا يوجد إدخال تفاعلي متاح (لا stdin ولا /dev/tty).\e[0m"
    echo -e "\e[33m[!] استخدم طريقة التشغيل الصحيحة:\e[0m"
    echo -e "\e[36m    sudo bash -c \"\$(curl -fsSL <رابط السكريبت الخام>)\"\e[0m"
    exit 1
fi

# دالة تقرأ مدخل من المستخدم بحد أقصى من المحاولات، مع تحقق بـ regex اختياري
# الاستخدام: read_validated "النص المعروض" "regex" "قيمة افتراضية"
read_validated() {
    local prompt="$1" pattern="$2" default="${3:-}"
    local value attempts=0
    while true; do
        read -r -p "$prompt" value
        value=${value:-$default}
        if [ -z "$pattern" ] || [[ $value =~ $pattern ]]; then
            echo "$value"
            return 0
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
            echo -e "\e[31m[-] تم الإدخال الخاطئ عدة مرات ($MAX_ATTEMPTS). جاري إيقاف السكريبت.\e[0m" >&2
            exit 1
        fi
        echo -e "\e[31m[-] قيمة غير صحيحة، حاول مجدداً ($attempts/$MAX_ATTEMPTS).\e[0m" >&2
    done
}

# 1. منع cloud-init من تخريب إعدادات الشبكة
echo -e "\n\e[33m[*] جاري تعطيل تحكم cloud-init في الشبكة...\e[0m"
mkdir -p /etc/cloud/cloud.cfg.d/
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# 2. اكتشاف كارت الشبكة الفعال تلقائياً
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip -br link show | grep -v LO | awk '{print $1}' | head -n1)
fi

# 3. طلب المدخلات من المستخدم
IFACE=$(read_validated "اسم كارت الشبكة [اضغط Enter للموافقة على $DEFAULT_IFACE]: " "" "$DEFAULT_IFACE")

IP_REGEX='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
IP=$(read_validated "أدخل الأي بي الجديد المطلوب (مثال: 192.168.1.101): " "$IP_REGEX")

CIDR_REGEX='^([1-9]|[12][0-9]|3[0-2])$'
NETMASK=$(read_validated "أدخل الـ Subnet Mask كـ CIDR (مثال: 24 للـ 255.255.255.0): " "$CIDR_REGEX")

GATEWAY=$(read_validated "أدخل عنوان الجيت واي (Gateway) (مثال: 192.168.1.1): " "$IP_REGEX")

DNS1=$(read_validated "أدخل الـ DNS الأول [اضغط Enter للموافقة على 8.8.8.8]: " "" "8.8.8.8")
DNS2=$(read_validated "أدخل الـ DNS الثاني [اضغط Enter للموافقة على 1.1.1.1]: " "" "1.1.1.1")

# 4. تنظيف الفولدر وعمل نسخة احتياطية
echo -e "\n\e[33m[*] جاري تنظيف ملفات Netplan القديمة وتجهيز الملف الجديد...\e[0m"
mkdir -p /etc/netplan/backup_old_yaml/
mv /etc/netplan/*.yaml /etc/netplan/backup_old_yaml/ 2>/dev/null

# 5. كتابة ملف الـ Netplan الجديد بالصيغة الحديثة الموحدة
cat <<EOF > /etc/netplan/01-static-managed.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses:
        - $IP/$NETMASK
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF

# 6. تطبيق الإعدادات مع ميزة الأمان للأوبنتو (netplan try)
echo -e "\n\e[32m[*] جاري اختبار الإعدادات الجديدة بأمان...\e[0m"
echo -e "\e[33m[تنبيه] إذا انقطع اتصالك، انتظر دقيقتين وسيقوم السيرفر بالتراجع تلقائياً.\e[0m"

if netplan try --timeout 60; then
    echo -e "\n\e[32m[✓] تم تطبيق الأي بي الثابت بنجاح وتأكيده بالتجربة!\e[0m"
    echo -e "\e[34mالأي بي الحالي لـ $IFACE هو:\e[0m"
    ip addr show "$IFACE" | grep inet
else
    echo -e "\n\e[31m[-] تم إلغاء التغييرات أو حدث خطأ أثناء تطبيق الإعدادات.\e[0m"
fi
